//! Pinned beta installer. Never install an unverified or stale partial download.
use std::{path::Path, sync::atomic::{AtomicBool, Ordering}, time::Duration};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Manager, State, Window};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use crate::{device::DeviceInfoMutex, error::AppError, operation::Operation,
    sideload::{sideload, SideloaderMutex}};

const URL: &str = "https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build57-livecontainer-beta/Gnarly-57-Continuity.ipa";
const SHA256: &str = "a12387c7bd3d361c8dd3eeb78ad090559e0e0c24111f15ef0c03e3a8f6440dc9";
const SIZE: u64 = 112107110;
static BUSY: AtomicBool = AtomicBool::new(false);
struct Lease;
impl Drop for Lease { fn drop(&mut self) { BUSY.store(false, Ordering::Release); } }
fn fs_error(e: std::io::Error) -> AppError { AppError::Filesystem("Cache do Gnarly".into(), e.to_string()) }

fn validate_digest(size: u64, digest: &str) -> Result<(), AppError> {
    if size != SIZE || digest != SHA256 {
        return Err(AppError::Download("O arquivo não corresponde ao Gnarly build 57. Tente baixar novamente.".into()));
    }
    Ok(())
}

async fn verify(path: &Path) -> Result<(), AppError> {
    let mut file = tokio::fs::File::open(path).await.map_err(fs_error)?;
    let mut buffer = vec![0_u8; 128 * 1024];
    let mut hash = Sha256::new();
    let mut size = 0;
    loop {
        let n = file.read(&mut buffer).await.map_err(fs_error)?;
        if n == 0 { break; }
        hash.update(&buffer[..n]); size += n as u64;
        if size > SIZE { return validate_digest(size, ""); }
    }
    validate_digest(size, &format!("{:x}", hash.finalize()))
}

async fn prepare(handle: &AppHandle) -> Result<String, AppError> {
    let dir = handle.path().app_cache_dir().map_err(|e| AppError::Misc(e.to_string()))?;
    tokio::fs::create_dir_all(&dir).await.map_err(fs_error)?;
    let dest = dir.join("Gnarly-57-Continuity.ipa");
    if verify(&dest).await.is_ok() { return Ok(dest.to_string_lossy().into_owned()); }
    if dest.exists() { tokio::fs::remove_file(&dest).await.map_err(fs_error)?; }
    let partial = dir.join("Gnarly-57-Continuity.ipa.partial");
    let client = reqwest::Client::builder().connect_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(900)).user_agent("Gnarly-Installer/0.1.0")
        .build().map_err(|e| AppError::Download(e.to_string()))?;
    let mut response = client.get(URL).send().await
        .and_then(|r| r.error_for_status()).map_err(|e| AppError::Download(e.to_string()))?;
    let mut file = tokio::fs::File::create(&partial).await.map_err(fs_error)?;
    let mut size = 0;
    while let Some(chunk) = response.chunk().await.map_err(|e| AppError::Download(e.to_string()))? {
        size += chunk.len() as u64;
        if size > SIZE { return Err(AppError::Download("Download maior que o esperado.".into())); }
        file.write_all(&chunk).await.map_err(fs_error)?;
    }
    file.flush().await.map_err(fs_error)?;
    drop(file);
    verify(&partial).await?;
    tokio::fs::rename(&partial, &dest).await.map_err(fs_error)?;
    Ok(dest.to_string_lossy().into_owned())
}

#[tauri::command]
pub async fn install_gnarly_operation(handle: AppHandle, window: Window,
    device_state: State<'_, DeviceInfoMutex>, sideloader_state: State<'_, SideloaderMutex>,
    expected_udid: String, expected_email: String) -> Result<(), AppError> {
    if BUSY.swap(true, Ordering::AcqRel) { return Err(AppError::Misc("Já existe uma instalação em andamento.".into())); }
    let _lease = Lease;
    let op = Operation::new("install_gnarly".into(), &window);
    op.start("download")?;
    let path = op.fail_if_err("download", prepare(&handle).await)?;
    op.move_on("download", "install")?;
    let ready = (|| {
        let state = device_state.lock().unwrap();
        let d = state.as_ref().ok_or(AppError::NoDeviceSelected)?;
        if d.info.udid != expected_udid || d.info.connection_type != "USB" {
            return Err(AppError::Misc("O iPhone selecionado mudou. Confirme o aparelho e tente novamente.".into()));
        }
        if d.info.version.split('.').next().and_then(|n| n.parse::<u32>().ok()).unwrap_or(0) < 17 {
            return Err(AppError::Misc("O Gnarly requer iOS 17 ou superior.".into()));
        }
        Ok(())
    })();
    op.fail_if_err("install", ready)?;
    let actual_email = crate::account::logged_in_as(sideloader_state.clone());
    op.fail_if_err("install", if actual_email.as_deref() == Some(&expected_email) { Ok(()) }
        else { Err(AppError::Misc("A conta Apple mudou. Confirme a conta e tente novamente.".into())) })?;
    op.fail_if_err("install", sideload(device_state, sideloader_state, path).await)?;
    op.complete("install")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn correct_release_only() {
        assert!(validate_digest(SIZE, SHA256).is_ok());
        assert!(validate_digest(SIZE - 1, SHA256).is_err());
        assert!(validate_digest(SIZE + 1, SHA256).is_err());
        assert!(validate_digest(SIZE, &"0".repeat(64)).is_err());
    }
    #[tokio::test] async fn real_release_when_provided() {
        if let Some(path) = std::env::var_os("GNARLY_IPA_TEST") { verify(Path::new(&path)).await.unwrap(); }
    }
    #[tokio::test] async fn partial_archive_rejected() {
        let path = std::env::temp_dir().join(format!("gnarly-test-{}", uuid::Uuid::new_v4()));
        tokio::fs::write(&path, b"truncated archive").await.unwrap();
        assert!(verify(&path).await.is_err());
        tokio::fs::remove_file(path).await.unwrap();
    }
}
