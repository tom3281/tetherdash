#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(NetworkBytesPlugin, "NetworkBytes",
    CAP_PLUGIN_METHOD(readCounters, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getRadioTech, CAPPluginReturnPromise);
)
