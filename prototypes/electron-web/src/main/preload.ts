import { contextBridge, ipcRenderer } from 'electron';

let segPortResolve: ((p: MessagePort) => void) | null = null;
ipcRenderer.on('seg:port', (e) => { segPortResolve?.(e.ports[0]); });

contextBridge.exposeInMainWorld('host', {
  config: () => ipcRenderer.invoke('config'),
  emit: (metric: string, value: unknown, unit: string, extra?: Record<string, unknown>) => ipcRenderer.invoke('emit', metric, value, unit, extra),
  log: (...m: unknown[]) => ipcRenderer.invoke('log', ...m),
  samplerStart: () => ipcRenderer.invoke('sampler:start'),
  samplerStop: () => ipcRenderer.invoke('sampler:stop'),
  screenshot: (name: string) => ipcRenderer.invoke('screenshot', name),
  done: (code?: number) => ipcRenderer.invoke('done', code),
  probe: (file: string) => ipcRenderer.invoke('probe', file),
  fileOpen: (name: string) => ipcRenderer.invoke('file:open', name),
  fileWrite: (id: number, data: Uint8Array, pos: number) => ipcRenderer.invoke('file:write', id, data, pos),
  fileClose: (id: number) => ipcRenderer.invoke('file:close', id),
  stt: (wav: string) => ipcRenderer.invoke('stt:run', wav),
  // MessagePorts cannot cross the contextBridge directly; we forward it via window.postMessage.
  segConnect: (opts: object) => new Promise<void>((resolve) => {
    segPortResolve = (port) => { window.postMessage('seg:port', '*', [port]); resolve(); };
    ipcRenderer.send('seg:connect', opts);
  }),
});
