"""Exact HTDemucs stages. Attention remains global; only its evaluation is tiled.

MIT, derived from Meta Demucs and the pinned Gnarly full-precision converter.
No shortened segment, quantized weights, sparse approximation or retraining.
"""
import torch
from torch import nn
from torch.nn import functional as F
from einops import rearrange
from demucs.transformer import create_2d_sin_embedding


class Encode(nn.Module):
    def __init__(self, m, index):
        super().__init__()
        self.spectral = m.encoder[index]
        self.temporal = m.tencoder[index]
        assert not self.temporal.empty
        self.first = index == 0
        if self.first:
            self.embedding = m.freq_emb
            self.embedding_scale = m.freq_emb_scale

    def forward(self, x, xt):
        if self.first:
            mean = x.mean((1, 2, 3), keepdim=True)
            std = x.std((1, 2, 3), keepdim=True)
            meant = xt.mean((1, 2), keepdim=True)
            stdt = xt.std((1, 2), keepdim=True)
            stats = torch.cat([mean.flatten(), std.flatten(), meant.flatten(), stdt.flatten()])
            x = (x - mean) / (1e-5 + std)
            xt = (xt - meant) / (1e-5 + stdt)
        xt = self.temporal(xt)
        x = self.spectral(x)
        if self.first:
            frequencies = torch.arange(x.shape[-2], device=x.device)
            x = x + self.embedding_scale * self.embedding(frequencies).t()[None, :, :, None].expand_as(x)
            return x, xt, stats
        return x, xt


class TransformerIn(nn.Module):
    def __init__(self, m, spectral_shape, temporal_shape):
        super().__init__()
        assert m.bottom_channels
        self.up = m.channel_upsampler
        self.up_t = m.channel_upsampler_t
        tr = m.crosstransformer
        self.norm = tr.norm_in
        self.norm_t = tr.norm_in_t
        _, _, fr, t = spectral_shape
        dim = m.bottom_channels
        self.register_buffer('pos', rearrange(create_2d_sin_embedding(dim, fr, t, torch.device('cpu'), tr.max_period),
                                             'b c fr t -> b (t fr) c') * tr.weight_pos_embed)
        self.register_buffer('pos_t', rearrange(tr._get_pos_embedding(temporal_shape[-1], 1, dim, torch.device('cpu')),
                                               't b c -> b t c') * tr.weight_pos_embed)

    def forward(self, x, xt):
        b, c, f, t = x.shape
        x = self.up(x.reshape(b, c, f * t)).reshape(b, -1, f, t)
        xt = self.up_t(xt)
        return self.norm(rearrange(x, 'b c f t -> b (t f) c')) + self.pos, self.norm_t(xt.transpose(1, 2)) + self.pos_t


class AttentionProjection(nn.Module):
    def __init__(self, layer, classic):
        super().__init__()
        self.classic = classic
        self.norm_first = layer.norm_first
        self.norm1 = layer.norm1
        if not classic:
            self.norm2 = layer.norm2
        attention = layer.self_attn if classic else layer.cross_attn
        assert isinstance(attention, nn.MultiheadAttention) and attention.batch_first
        assert attention.bias_k is None and attention.bias_v is None and not attention.add_zero_attn
        self.weight = nn.Parameter(attention.in_proj_weight.detach().clone())
        self.bias = nn.Parameter(attention.in_proj_bias.detach().clone())
        self.heads = attention.num_heads
        self.dim = attention.embed_dim

    def split_heads(self, value):
        return value.reshape(1, value.shape[1], self.heads, self.dim // self.heads).permute(0, 2, 1, 3)

    def forward(self, x, other):
        q = self.norm1(x) if self.norm_first else x
        if self.classic:
            q, k, v = F.linear(q, self.weight, self.bias).chunk(3, dim=-1)
        else:
            key = self.norm2(other) if self.norm_first else other
            q = F.linear(q, self.weight[:self.dim], self.bias[:self.dim])
            k, v = F.linear(key, self.weight[self.dim:], self.bias[self.dim:]).chunk(2, dim=-1)
        return self.split_heads(q), self.split_heads(k), self.split_heads(v)


class Projections(nn.Module):
    def __init__(self, tr, index):
        super().__init__()
        classic = index % 2 == tr.classic_parity
        self.a = AttentionProjection(tr.layers[index], classic)
        self.b = AttentionProjection(tr.layers_t[index], classic)

    def forward(self, x, xt):
        return (*self.a(x, xt), *self.b(xt, x))


class AttentionFinish(nn.Module):
    def __init__(self, layer, classic):
        super().__init__()
        self.classic = classic
        self.norm_first = layer.norm_first
        self.projection = (layer.self_attn if classic else layer.cross_attn).out_proj
        self.gamma1, self.gamma2 = layer.gamma_1, layer.gamma_2
        self.norm1, self.norm2 = layer.norm1, layer.norm2
        if not classic:
            self.norm3 = layer.norm3
        self.norm_out = layer.norm_out
        self.linear1, self.linear2 = layer.linear1, layer.linear2
        self.activation = layer.activation

    def feedforward(self, x):
        return self.linear2(self.activation(self.linear1(x)))

    def forward(self, residual, attention):
        b, h, n, d = attention.shape
        result = self.projection(attention.transpose(1, 2).reshape(b, n, h * d))
        if self.norm_first:
            x = residual + self.gamma1(result)
            normalized = self.norm2(x) if self.classic else self.norm3(x)
            x = x + self.gamma2(self.feedforward(normalized))
            if self.norm_out is not None:
                x = self.norm_out(x)
        else:
            x = self.norm1(residual + self.gamma1(result))
            x = self.norm2(x + self.gamma2(self.feedforward(x)))
        return x


class Finishes(nn.Module):
    def __init__(self, tr, index):
        super().__init__()
        classic = index % 2 == tr.classic_parity
        self.a = AttentionFinish(tr.layers[index], classic)
        self.b = AttentionFinish(tr.layers_t[index], classic)

    def forward(self, x, xt, attention, attention_t):
        return self.a(x, attention), self.b(xt, attention_t)


class TransformerOut(nn.Module):
    def __init__(self, m, frequencies, frames):
        super().__init__()
        self.down = m.channel_downsampler
        self.down_t = m.channel_downsampler_t
        self.frequencies, self.frames = frequencies, frames

    def forward(self, x, xt):
        x = rearrange(x, 'b (t f) c -> b c f t', t=self.frames, f=self.frequencies)
        b, c, f, t = x.shape
        x = self.down(x.reshape(b, c, f * t)).reshape(b, -1, f, t)
        return x, self.down_t(xt.transpose(1, 2))


class DecodeSpectral(nn.Module):
    def __init__(self, m, index, length):
        super().__init__()
        self.layer = m.decoder[index]
        # With this pinned checkpoint, the optional global GroupNorms are
        # identities. Any DConv normalizes each frequency independently.
        assert not self.layer.norm
        self.length = length
        self.last = index == len(m.decoder) - 1

    def forward(self, x, skip, stats):
        x, _ = self.layer(x, skip, self.length)
        if self.last:
            x = x.reshape(1, 4, 4, x.shape[-2], 336) * stats[1] + stats[0]
        return x


class DecodeTemporal(nn.Module):
    def __init__(self, m, index, length):
        super().__init__()
        self.layer = m.tdecoder[index]
        self.length = length
        self.last = index == len(m.tdecoder) - 1

    def forward(self, x, skip, stats):
        x, _ = self.layer(x, skip, self.length)
        if self.last:
            x = x.reshape(1, 4, 2, 343980) * stats[3] + stats[2]
        return x


def tiled_attention(q, k, v, block=64):
    # Global keys/values and the full softmax domain for every query. The
    # temporary score matrix is [heads, block, all_keys], never [N, N].
    return torch.cat([F.scaled_dot_product_attention(q[:, :, i:i+block], k, v)
                      for i in range(0, q.shape[2], block)], dim=2)


def stages(m, mix, spectrum):
    state = {'mix': mix, 'spec': spectrum}
    instructions = []
    modules = []
    spectral_lengths, temporal_lengths = [], []
    def apply(name, module, inputs, outputs):
        module.eval()
        args = tuple(state[key].contiguous() for key in inputs)
        values = module(*args)
        if not isinstance(values, tuple): values = (values,)
        assert len(values) == len(outputs)
        state.update(zip(outputs, values))
        instruction = {'name': name, 'kind': 'coreml', 'inputs': inputs, 'outputs': outputs,
                       'input_shapes': [list(x.shape) for x in args], 'output_shapes': [list(x.shape) for x in values]}
        instructions.append(instruction)
        modules.append((instruction, module, args))
    for i in range(4):
        inputs = ['spec', 'mix'] if i == 0 else [f's{i-1}', f't{i-1}']
        spectral_lengths.append(state[inputs[0]].shape[-1])
        temporal_lengths.append(state[inputs[1]].shape[-1])
        outputs = [f's{i}', f't{i}'] + (['stats'] if i == 0 else [])
        apply(f'encode{i}', Encode(m, i), inputs, outputs)
    shape, tshape = state['s3'].shape, state['t3'].shape
    apply('transform_in', TransformerIn(m, shape, tshape), ['s3', 't3'], ['x0', 'xt0'])
    for i in range(m.crosstransformer.num_layers):
        inputs = [f'x{i}', f'xt{i}']
        qkv = [f'{lane}{i}' for lane in ['q', 'k', 'v', 'qt', 'kt', 'vt']]
        apply(f'project{i}', Projections(m.crosstransformer, i), inputs, qkv)
        out = [f'attention{i}', f'attention_t{i}']
        for offset, key in [(0, out[0]), (3, out[1])]:
            state[key] = tiled_attention(*(state[k] for k in qkv[offset:offset+3]))
        instructions.append({'name': f'attention{i}', 'kind': 'attention', 'inputs': qkv, 'outputs': out,
                             'input_shapes': [list(state[k].shape) for k in qkv],
                             'output_shapes': [list(state[k].shape) for k in out]})
        apply(f'finish{i}', Finishes(m.crosstransformer, i), inputs+out, [f'x{i+1}', f'xt{i+1}'])
    n = m.crosstransformer.num_layers
    apply('transform_out', TransformerOut(m, shape[2], shape[3]), [f'x{n}', f'xt{n}'], ['ds0', 'dt0'])
    for i in range(4):
        spectral_output = f'ds{i+1}' if i != 3 else 'frequency'
        temporal_output = f'dt{i+1}' if i != 3 else 'time'
        spectral_inputs = [f'ds{i}', f's{3-i}', 'stats']
        module = DecodeSpectral(m, i, spectral_lengths[3-i]).eval()
        full_args = tuple(state[key].contiguous() for key in spectral_inputs)
        frequencies = full_args[0].shape[-2]
        if frequencies <= 32:
            apply(f'decode_s{i}', module, spectral_inputs, [spectral_output])
        else:
            chunks, variants = [], {}
            for start in range(0, frequencies, 32):
                end = min(frequencies, start + 32)
                lo, hi = max(0, start - 2), min(frequencies, end + 2)
                args = (full_args[0][..., lo:hi, :].contiguous(),
                        full_args[1][..., lo:hi, :].contiguous(), full_args[2])
                output = module(*args)
                offset, count = (start - lo) * 4, (end - start) * 4
                chunks.append(output[..., offset:offset + count, :])
                variant = 'edge' if hi - lo == 34 else 'inner'
                variants[variant] = args
            state[spectral_output] = torch.cat(chunks, dim=-2)
            instructions.append({'name': f'decode_s{i}', 'kind': 'spectral_decode',
                                 'inputs': spectral_inputs, 'outputs': [spectral_output],
                                 'input_shapes': [list(x.shape) for x in full_args],
                                 'output_shapes': [list(state[spectral_output].shape)]})
            for variant, args in variants.items():
                outputs = module(*args)
                descriptor = {'name': f'decode_s{i}_{variant}', 'outputs': [spectral_output]}
                modules.append((descriptor, module, args))
        apply(f'decode_t{i}', DecodeTemporal(m, i, temporal_lengths[3-i]),
              [f'dt{i}', f't{3-i}', 'stats'], [temporal_output])
    instructions[0]['working_memory_bytes'] = 384 * 1024 * 1024
    return instructions, modules, state['frequency'], state['time']
