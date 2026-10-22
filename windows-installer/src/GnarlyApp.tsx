import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { AppleID } from "./AppleID";
import { DeviceInfo } from "./Device";
import { AppError } from "./errors";
import "./App.css";
import "./GnarlyApp.css";

type Phone = Omit<DeviceInfo, "uuid"> & { udid: string };
type Update = { stepId: string; updateType: string; extraDetails?: AppError };

export default function GnarlyApp() {
  const [email, setEmail] = useState<string | null>(null);
  const [secure, setSecure] = useState(false);
  const [phones, setPhones] = useState<Phone[]>([]);
  const [selected, setSelected] = useState<Phone | null>(null);
  const [pairing, setPairing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [deviceError, setDeviceError] = useState("");
  const [status, setStatus] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const listing = useRef(false);
  const pairSequence = useRef(0);
  const current = useRef<Phone | null>(null);
  const active = useRef(false);

  useEffect(() => { void invoke<boolean>("keyring_available").then(setSecure).catch(() => setSecure(false)); }, []);
  useEffect(() => { setConfirmed(false); setStatus(""); setError(""); }, [email, selected?.udid]);
  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void listen<Update>("operation_install_gnarly", ({ payload }) => {
      if (payload.updateType === "started") setStatus(payload.stepId === "download"
        ? "Preparando e verificando o Gnarly 57…" : "Assinando e instalando no iPhone…");
      if (payload.updateType === "failed") setError(payload.extraDetails?.message ?? "A instalação falhou.");
    }).then(fn => { if (cancelled) fn(); else unlisten = fn; });
    return () => { cancelled = true; unlisten?.(); };
  }, []);

  useEffect(() => {
    let stopped = false;
    const refresh = async () => {
      if (listing.current || active.current) return;
      listing.current = true;
      try {
        const result = await invoke<({ Ok: Phone } | { Err: AppError })[]>("list_devices");
        if (stopped) return;
        const usb = result.flatMap(r => "Ok" in r && r.Ok.connectionType === "USB" ? [r.Ok] : []);
        setPhones(usb);
        const failure = result.find(r => "Err" in r);
        setDeviceError(failure && "Err" in failure ? failure.Err.message : "");
        if (current.current && !usb.some(d => d.udid === current.current!.udid)) {
          current.current = null; setSelected(null); setConfirmed(false);
          await invoke("set_selected_device", { device: null });
        }
      } catch {
        if (!stopped) {
          setDeviceError("Conecte e desbloqueie o iPhone. Se ele não aparecer, instale o aplicativo Dispositivos Apple no Windows.");
          setPhones([]); current.current = null; setSelected(null);
        }
      } finally { listing.current = false; }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 3000);
    return () => { stopped = true; clearInterval(timer); };
  }, []);

  const pair = async (phone: Phone) => {
    if (active.current) return;
    const sequence = ++pairSequence.current;
    active.current = true; setPairing(true); setError(""); setConfirmed(false);
    current.current = null; setSelected(null);
    try {
      await invoke("set_selected_device", { device: phone });
      if (sequence === pairSequence.current) { current.current = phone; setSelected(phone); }
    } catch (e) { if (sequence === pairSequence.current) setError((e as AppError).message ?? String(e)); }
    finally { if (sequence === pairSequence.current) { active.current = false; setPairing(false); } }
  };

  const install = async () => {
    if (!selected || !email || !confirmed || active.current) return;
    active.current = true; setBusy(true); setError(""); setStatus("Preparando o Gnarly…");
    try {
      await invoke("install_gnarly_operation", { expectedUdid: selected.udid, expectedEmail: email });
      setStatus("Gnarly instalado. No iPhone, confie no perfil em Ajustes › Geral › VPN e Gerenciamento de Dispositivo e ative o Modo Desenvolvedor, se solicitado.");
    } catch (e) { setStatus(""); setError((e as AppError).message ?? String(e)); }
    finally { active.current = false; setBusy(false); }
  };

  return <main className="gnarly-shell">
    <header><span className="gnarly-mark" aria-hidden="true">G</span><div><h1>Gnarly Installer</h1><p>Conecte. Entre na conta. Instale.</p></div><span className="beta">Windows · beta 0.1</span></header>
    <fieldset disabled={busy || pairing}>
      <section className="gnarly-panel"><p className="eyebrow">1 · Conta do dono do iPhone</p>
        <AppleID loggedInAs={email} setLoggedInAs={setEmail} noKeyringAvailable={!secure} />
        <p className="hint">Use a conta de cada amigo. Salvar o login é opcional; quando habilitado, a senha fica no cofre do Windows. A autenticação usa o mecanismo do iloader, incluindo um serviço externo de anisette.</p>
      </section>
      <section className="gnarly-panel"><p className="eyebrow">2 · iPhone conectado pelo cabo</p>
        <p>Desbloqueie o iPhone e toque em <strong>Confiar neste computador</strong>.</p>
        {phones.map(phone => <button key={phone.udid} className={selected?.udid === phone.udid ? "phone chosen" : "phone"} onClick={() => void pair(phone)}>{phone.name} · iOS {phone.version}{selected?.udid === phone.udid ? " · selecionado" : " · selecionar"}</button>)}
        {!phones.length && <p className="hint">Aguardando iPhone… A lista atualiza automaticamente.</p>}
        {deviceError && <p className="hint">{deviceError}</p>}
        <button className="link-button" onClick={() => void openUrl("https://apps.microsoft.com/detail/9np83lwlpz9k")}>Instalar / abrir Dispositivos Apple</button>
      </section>
      <section className="gnarly-panel"><p className="eyebrow">3 · Instalar ou renovar</p>
        <h2>Gnarly · build 57</h2><p>Omnibox, stems e karaokê. O download é verificado e reutilizado nas próximas instalações.</p>
        <label className="confirm"><input type="checkbox" checked={confirmed} disabled={!selected || !email} onChange={e => setConfirmed(e.target.checked)} />Confirmo: {selected?.name ?? "selecione o iPhone"} pertence à conta {email ?? "selecione a conta Apple"}.</label>
        <button className="install" disabled={!confirmed || !selected || !email || Number(selected.version.split(".")[0]) < 17} onClick={() => void install()}>Instalar / renovar Gnarly</button>
        {selected && Number(selected.version.split(".")[0]) < 17 && <p role="alert">É necessário iOS 17 ou superior.</p>}
        <p className="hint">Conta gratuita: renove pelo cabo antes de completar 7 dias. Para preservar os dados, use a mesma conta e não desinstale o Gnarly. A instalação dentro do LiveContainer tem dados separados.</p>
      </section>
    </fieldset>
    {pairing && <section className="gnarly-panel" role="status"><p>Aguardando confirmação no iPhone. Mantenha a tela desbloqueada.</p><button onClick={() => void invoke("cancel_pairing").catch(() => {})}>Cancelar conexão</button></section>}
    {status && <section className="gnarly-panel" role="status" aria-live="polite">{status}</section>}
    {error && <section className="gnarly-panel error" role="alert">{error}</section>}
    <footer>Derivado independente do <button className="link-button" onClick={() => void openUrl("https://github.com/nab138/iloader")}>iloader (MIT)</button>. Sem afiliação ao projeto original. iOS 17+; stems locais requerem iOS 18+.</footer>
  </main>;
}
