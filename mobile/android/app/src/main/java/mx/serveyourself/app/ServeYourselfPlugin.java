package mx.serveyourself.app;

import android.content.Intent;
import android.net.Uri;
import android.print.PrintManager;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "ServeYourself")
public class ServeYourselfPlugin extends Plugin {
    @PluginMethod
    public void getScheme(PluginCall call) {
        call.resolve(new JSObject().put("scheme", getContext().getPackageName()));
    }

    @PluginMethod
    public void openGoogle(PluginCall call) {
        Uri url = Uri.parse(call.getString("url", ""));
        String callback = url.getQueryParameter("redirect_to");
        String validPrefix = getContext().getPackageName() + "://auth/";
        if (callback == null || !callback.startsWith(validPrefix) ||
                !"s256".equalsIgnoreCase(url.getQueryParameter("code_challenge_method")) ||
                !"https".equals(url.getScheme()) || !"spbgledcjwtqmlqdlpyx.supabase.co".equals(url.getAuthority()) ||
                !"/auth/v1/authorize".equals(url.getPath()) || !"google".equals(url.getQueryParameter("provider"))) {
            call.reject("Enlace de acceso no válido.");
            return;
        }
        try {
            getActivity().startActivity(new Intent(Intent.ACTION_VIEW, url).addCategory(Intent.CATEGORY_BROWSABLE));
            call.resolve();
        } catch (Exception error) {
            call.reject("No se encontró un navegador para iniciar sesión.");
        }
    }

    @PluginMethod
    public void print(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            PrintManager manager = getActivity().getSystemService(PrintManager.class);
            if (manager == null) {
                call.reject("La impresión no está disponible en este dispositivo.");
                return;
            }
            manager.print("ServeYourself", bridge.getWebView().createPrintDocumentAdapter("ServeYourself"), null);
            call.resolve();
        });
    }
}
