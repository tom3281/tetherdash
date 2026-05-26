#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(LocalServerPlugin, "LocalServer",
    CAP_PLUGIN_METHOD(start, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(stop, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(updateState, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getStatus, CAPPluginReturnPromise);
)
