// Local browser integration test with mocked native commands; no Apple credentials.
// Requires Playwright, a browser and `bun run dev --host 127.0.0.1`.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless:true, args:['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport:{width:1050,height:1200}});
    const failures=[]; page.on('pageerror',e=>failures.push(e.message));
    await page.addInitScript(() => {
      window.testPhones=[]; window.testEmail='friend@example.invalid'; window.testInstalls=[];
      let counter=1;
      const callbacks={}; const events={};
      window.testEmitEvent=(name,payload)=>callbacks[events[name]]({event:name,id:1,payload});
      window.testEmits=[];
      window.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener:()=>{}};
      window.__TAURI_INTERNALS__={
        transformCallback:fn=>{const id=counter++; callbacks[id]=fn; return id;},
        invoke:async (cmd,args)=> {
          if(cmd==='plugin:store|load') return 1;
          if(cmd==='plugin:store|keys') return [];
          if(cmd==='plugin:store|get') return [undefined,false];
          if(cmd==='plugin:event|listen') {events[args.event]=args.handler; return counter++;}
          if(cmd==='plugin:event|emit') {window.testEmits.push(args); return;}
          if(cmd==='keyring_available') return true;
          if(cmd==='logged_in_as') return window.testEmail;
          if(cmd==='invalidate_account') {window.testEmail=null;return;}
          if(cmd==='list_devices') return window.testPhones.map(Ok=>({Ok}));
          if(cmd==='set_selected_device') {window.testSelection=args.device;return;}
          if(cmd==='install_gnarly_operation') {window.testInstalls.push(args);await new Promise(resolve=>window.testFinishInstall=resolve);return;}
          return null;
        }
      };
    });
    await page.goto('http://127.0.0.1:1420');
    const install = page.getByRole('button',{name:'Instalar / renovar Gnarly',exact:true});
    await install.waitFor(); assert(await install.isDisabled());
    await page.evaluate(()=>window.testPhones=[{name:'iPhone do amigo',id:1,udid:'test-phone-1',connectionType:'USB',version:'18.7'}]);
    await page.getByRole('button',{name:/iPhone do amigo/}).click();
    assert(await install.isDisabled());
    await page.locator('.confirm input').check();
    assert(await install.isEnabled());
    await install.click();
    // Native signing may need a certificate choice while the main form is locked.
    await page.waitForFunction(()=>Boolean(window.testFinishInstall));
    assert(await install.isDisabled());
    await page.evaluate(()=>window.testEmitEvent('max-certs-reached',[{name:'Existing certificate',serialNumber:'serial-1',machineName:'Other tool'}]));
    await page.getByRole('heading',{name:'Limite de certificados alcançado'}).waitFor();
    await page.getByText('Escolha o que anular',{exact:true}).click();
    const cert=page.locator('#serial-1');
    assert(await cert.isEnabled()); assert(!(await cert.isChecked()));
    await page.locator(".cert-item").filter({hasText:"Existing certificate"}).click();
    assert(await cert.isChecked());
    await page.getByRole('button',{name:'Continuar',exact:true}).click();
    assert.deepEqual(await page.evaluate(()=>window.testEmits.find(e=>e.event==='max-certs-response').payload),['serial-1']);
    await page.evaluate(()=>window.testFinishInstall());
    await page.getByRole('status').filter({hasText:'Gnarly instalado.'}).waitFor();
    assert.deepEqual(await page.evaluate(()=>window.testInstalls),[{expectedUdid:'test-phone-1',expectedEmail:'friend@example.invalid'}]);
    // Disconnect must invalidate target and confirmation; no implicit install on reconnect.
    await page.evaluate(()=>window.testPhones=[]);
    await page.getByText('Aguardando iPhone…').waitFor();
    assert(await install.isDisabled()); assert(!(await page.locator('.confirm input').isChecked()));
    assert.equal(await page.getByRole('status').filter({hasText:'Gnarly instalado.'}).count(),0);
    await page.evaluate(()=>window.testPhones=[{name:'Outro iPhone',id:2,udid:'test-phone-2',connectionType:'USB',version:'16.7'}]);
    await page.getByRole('button',{name:/Outro iPhone/}).click();
    await page.locator('.confirm input').check();
    assert(await install.isDisabled());
    await page.getByRole('alert').filter({hasText:'iOS 17'}).waitFor();
    assert.equal(await page.evaluate(()=>window.testInstalls.length),1);
    assert.deepEqual(failures,[]);
    await page.screenshot({path:'/workspace/gnarly-installer-ui-smoke.png',fullPage:true});
    console.log('PASS: account/device gating, exact native request, disconnect invalidation, no automatic reinstall, unsupported iOS rejection, certificate prompt during signing with explicit choice; no browser errors.');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});
