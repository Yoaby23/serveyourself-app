const { contextBridge, ipcRenderer } = require('electron');

if (process.isMainFrame && location.origin === 'https://serveyourself-app.vercel.app') {
    contextBridge.exposeInMainWorld('serveYourselfDesktop', {
        authStart: destination => ipcRenderer.invoke('desktop:auth-start', destination),
        openGoogle: url => ipcRenderer.invoke('desktop:auth-open', url),
        print: () => ipcRenderer.invoke('desktop:print')
    });
}
