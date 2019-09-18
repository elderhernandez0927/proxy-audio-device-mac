#include <vector>
#include <CoreAudio/CoreAudio.h>
#import "WindowDelegate.h"
#include "AudioDevice.h"
#include "ProxyAudioDevice.h"

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData);

@implementation WindowDelegate {
    std::vector<AudioDeviceID> currentDeviceList;
    int initializationAttemptInterval;
}

- (void)awakeFromNib
{
    self.deviceNameTextField.stringValue = NSLocalizedString(@"< Loading... >", nil);
    self.deviceNameTextField.enabled = NO;
    self.outputDeviceComboBox.enabled = NO;
    self.bufferSizeComboBox.enabled = NO;
    initializationAttemptInterval = 3;
    [self keepTryingToInitializeUntilSuccess];
}

- (IBAction)reload:(id)sender
{
#pragma unused(sender)
    [self initialize];
}

- (void)keepTryingToInitializeUntilSuccess
{
    // For some reason, sometimes when the app launches right after the system boots we'll get bunk data
    // for all of the connected audio devices. If that happens then we'll try to initialize again after
    // a few seconds. We're initially waiting three seconds because that seems to work. Using less time
    // can actually cause the audio server to crash, so we want to be careful not to query it too often!
    bool success = [self initialize];
    
    if (!success) {
        NSLog(@"NB: failed to initialize, will try again in a sec...");
        [NSTimer scheduledTimerWithTimeInterval:initializationAttemptInterval target:self selector:@selector(keepTryingToInitializeUntilSuccess) userInfo:nil repeats:NO];
        // Increase the length of time between attempting to initialize by two seconds each time, just to be safe:
        initializationAttemptInterval += 2;
    }
}

- (bool)initialize
{
    if (![self setCurrentProcessAsConfigurator]) {
        return false;
    }
    
    if (![self refreshOutputDevices]) {
        return false;
    }
    
    if (![self setupListenerForCurrentAudioDevices]) {
        return false;
    }
    
    self.deviceNameTextField.stringValue = [self currentDeviceName];
    [self.bufferSizeComboBox selectItemWithObjectValue:[self currentOutputDeviceBufferFrameSize]];
    
    self.deviceNameTextField.enabled = YES;
    self.outputDeviceComboBox.enabled = YES;
    self.bufferSizeComboBox.enabled = YES;
    
    return true;
}

- (bool)setCurrentProcessAsConfigurator {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    
    if (proxyAudioBox == kAudioObjectUnknown) {
        NSLog(@"Error: unable to find proxy audio device");
        return false;
    }
    
    if (!AudioDevice::setIdentifyValue(proxyAudioBox, getpid())) {
        NSLog(@"Error: unable to set current process as configurator");
        return false;
    }
    
    return true;
}

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData) {
#pragma unused(inObjectID, inNumberAddresses, inAddresses)
    dispatch_async(dispatch_get_main_queue(), ^{
        WindowDelegate *delegate = (__bridge WindowDelegate *)inClientData;
        [delegate refreshOutputDevices];
    });

    return noErr;
}

- (bool)setupListenerForCurrentAudioDevices {
    AudioObjectPropertyAddress listenerPropertyAddress = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    OSStatus err =
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &listenerPropertyAddress, &onDevicesChanged, (__bridge_retained void *)self);

    if (err != noErr) {
        NSLog(@"Error: could not set up listener for audio devices changing");
        return false;
    }
    
    return true;
}

- (NSString *)currentDeviceName {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceName));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    
    return result ? result : NSLocalizedString(@"< Proxy Audio Device not found >", nil);
}

- (IBAction)deviceNameEntered:(id)sender {
#pragma unused(sender)
    NSString *newName = [self.deviceNameTextField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (newName.length == 0) {
        self.deviceNameTextField.stringValue = [self currentDeviceName];
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(proxyAudioBox,
                               (__bridge_retained CFStringRef)[NSString stringWithFormat:@"deviceName=%@", newName]);
}

- (AudioDeviceID)currentOutputDevice {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::outputDevice));
    NSString *outputDeviceUID = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    
    return AudioDevice::audioDeviceIDForDeviceUID((__bridge_retained CFStringRef)outputDeviceUID);
}

- (bool)refreshOutputDevices {
    bool success = false;
    [self.outputDeviceComboBox removeAllItems];
    currentDeviceList = AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice();
    AudioDeviceID outputDevice = [self currentOutputDevice];
    
    for (unsigned int i = 0; i < currentDeviceList.size(); ++i) {
        NSString *deviceName = (__bridge_transfer NSString *)AudioDevice::copyObjectName(currentDeviceList[i]);
        
        if (!deviceName) {
            NSLog(@"Note: got null device name for audio device with device with ID: %d", currentDeviceList[i]);
            continue;
        }
        
        [self.outputDeviceComboBox addItemWithObjectValue:deviceName];
        
        if (outputDevice == currentDeviceList[i]) {
            [self.outputDeviceComboBox selectItemAtIndex:i];
        }
        
        success = true;
    }
    
    if (!success) {
        NSLog(@"Error: failed to get any information about current output devices!");
    }
    
    return success;
}

- (IBAction)outputDeviceSelected:(id)sender {
#pragma unused(sender)
    unsigned long index = (unsigned long)self.outputDeviceComboBox.indexOfSelectedItem;
    
    if (index < 0 || index >= currentDeviceList.size()) {
        NSLog(@"Error: got invalid selection index when trying to set output device");
        return;
    }

    NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(currentDeviceList[index]);
    
    if (!uid) {
        NSLog(@"Error: got invalid UID when trying to set output device");
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(proxyAudioBox,
                               (__bridge_retained CFStringRef)[NSString stringWithFormat:@"outputDevice=%@", uid]);
}

- (NSString *)currentOutputDeviceBufferFrameSize {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::outputDeviceBufferFrameSize));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    
    return result ? result : @"";
}

- (IBAction)outputDeviceBufferFrameSizeSelected:(id)sender {
#pragma unused(sender)
    NSString *newBufferFrameSizeString = self.bufferSizeComboBox.objectValueOfSelectedItem;

    if (!newBufferFrameSizeString) {
        NSLog(@"Error: got invalid buffer frame size value");
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(
        proxyAudioBox,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceBufferFrameSize=%@", newBufferFrameSizeString]);
}

@end
