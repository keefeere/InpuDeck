/**
 * Tools > USB Mode > USB-OTG (TinyUSB)
 * Tools > USB CDC On Boot > Enabled
 * Install library NimBLEDevice
 */

#include <Arduino.h>
#include <Preferences.h>
#include <esp_system.h>

#if !defined(ARDUINO_USB_MODE) || ARDUINO_USB_MODE != 0
#error "InpuDeck requires Tools > USB Mode > USB-OTG (TinyUSB)"
#endif

#if !defined(ARDUINO_USB_CDC_ON_BOOT) || ARDUINO_USB_CDC_ON_BOOT != 1
#error "InpuDeck provisioning requires Tools > USB CDC On Boot > Enabled"
#endif

// ---- BLE (Peripheral) via NimBLE ----
#include <NimBLEDevice.h>

// ---- USB HID Keyboard, Mouse & Consumer Control (Arduino-ESP32 core) ----
#include "USB.h"
#include "USBHID.h"
#include "USBHIDKeyboard.h"
#include "USBHIDMouse.h"
#include "USBHIDConsumerControl.h"

enum class BridgeLedState : uint8_t;

// =====================
// UUIDs (MUST MATCH iOS)
// =====================
static const char* kServiceUUID = "2D2A0001-8A5A-4E76-A2E3-1E57D9A1B001";
static const char* kWriteCharUUID = "2D2A0002-8A5A-4E76-A2E3-1E57D9A1B001";
static const char* kSecurityCharUUID = "2D2A0003-8A5A-4E76-A2E3-1E57D9A1B001";
static const char* kNameCharUUID = "2D2A0004-8A5A-4E76-A2E3-1E57D9A1B001";
static const char* kDefaultBridgeName = "InpuDeck Bridge";
static const char* kPreferencesNamespace = "inpudeck";
static const char* kBridgeNameKey = "bridge_name";
static const char* kPasskeyKey = "passkey";
static const char* kPairOnBootKey = "pair_on_boot";
static const char* kBleIdentityKey = "ble_identity";
static constexpr size_t kBleIdentityBytes = 6;
static constexpr size_t kMaxBridgeNameBytes = 28;
static constexpr uint32_t kMinimumPasskey = 100000;
static constexpr uint32_t kMaximumPasskey = 999999;
static constexpr uint8_t kPairButtonPin = 0;
static constexpr uint32_t kPairButtonHoldMs = 3000;
static constexpr uint32_t kBondResetHoldMs = 10000;
static constexpr uint32_t kPairingWindowMs = 120000;
static constexpr uint32_t kProvisionedPairingWindowMs = 300000;
static constexpr uint32_t kBondIdentityGraceMs = 2000;
static constexpr uint32_t kAuthenticationTimeoutMs = 10000;
static constexpr uint32_t kEnrollmentConnectionTimeoutMs = 60000;
static constexpr uint8_t kSecurityCapability[] = { 'I', 'D', 0x01, 0x0F };

static String gBridgeName = kDefaultBridgeName;
static String gSerialCommand;
static uint32_t gPasskey = 0;
static uint32_t gHiddenPasskey = 0;
static uint32_t gPairingWindowOpenedAtMs = 0;
static uint32_t gPairingWindowDurationMs = 0;
static volatile bool gPairingWindowOpen = false;
static bool gPairButtonDown = false;
static bool gPairButtonHandled = false;
static uint32_t gPairButtonDownAtMs = 0;
static volatile uint16_t gConnectedHandle = BLE_HS_CONN_HANDLE_NONE;
static volatile bool gConnectedWasBonded = false;
static volatile bool gConnectedSecure = false;
static volatile bool gConnectionSecurityStarted = false;
static volatile uint32_t gConnectedAtMs = 0;
static uint8_t gBleIdentity[kBleIdentityBytes] = {};
static bool gHasBleIdentity = false;

static bool isValidBridgeName(const String& name) {
  const size_t length = name.length();
  if (length == 0 || length > kMaxBridgeNameBytes) return false;

  for (size_t i = 0; i < length; ++i) {
    const uint8_t byte = static_cast<uint8_t>(name[i]);
    if (byte < 0x20 || byte == 0x7F) return false;
  }
  return true;
}

static String loadBridgeName() {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, true)) return kDefaultBridgeName;
  String name = preferences.getString(kBridgeNameKey, kDefaultBridgeName);
  preferences.end();
  name.trim();
  return isValidBridgeName(name) ? name : String(kDefaultBridgeName);
}

static bool storeBridgeName(const String& name) {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false)) return false;
  const size_t storedLength = preferences.putString(kBridgeNameKey, name);
  preferences.end();
  return storedLength == name.length();
}

static bool isValidPasskey(uint32_t passkey) {
  return passkey >= kMinimumPasskey && passkey <= kMaximumPasskey;
}

static uint32_t generatePasskey() {
  return kMinimumPasskey + (esp_random() % (kMaximumPasskey - kMinimumPasskey + 1));
}

static void generateBleIdentity(uint8_t* identity) {
  esp_fill_random(identity, kBleIdentityBytes);
  // A static random BLE address has its two most-significant bits set. Force
  // one zero and one one in the random part as well, satisfying the Bluetooth
  // requirement without a statistically improbable retry loop.
  identity[0] = (identity[0] & 0xFC) | 0x01;
  identity[5] = (identity[5] & 0x3F) | 0xC0;
}

static bool isValidBleIdentity(const uint8_t* identity) {
  if ((identity[5] & 0xC0) != 0xC0) return false;
  bool hasZero = false;
  bool hasOne = false;
  for (size_t i = 0; i < kBleIdentityBytes; ++i) {
    const uint8_t mask = i == kBleIdentityBytes - 1 ? 0x3F : 0xFF;
    const uint8_t byte = identity[i] & mask;
    if (byte != mask) hasZero = true;
    if (byte != 0x00) hasOne = true;
  }
  return hasZero && hasOne;
}

static bool loadBleIdentity(uint8_t* identity) {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, true)) return false;
  const size_t storedLength = preferences.getBytesLength(kBleIdentityKey);
  const size_t loaded = storedLength == kBleIdentityBytes
      ? preferences.getBytes(kBleIdentityKey, identity, kBleIdentityBytes)
      : 0;
  preferences.end();
  return loaded == kBleIdentityBytes && isValidBleIdentity(identity);
}

static uint32_t loadPasskey(bool* wasGenerated = nullptr) {
  Preferences preferences;
  uint32_t passkey = 0;
  if (preferences.begin(kPreferencesNamespace, true)) {
    passkey = preferences.getUInt(kPasskeyKey, 0);
    preferences.end();
  }
  if (isValidPasskey(passkey)) {
    if (wasGenerated != nullptr) *wasGenerated = false;
    return passkey;
  }

  passkey = generatePasskey();
  if (preferences.begin(kPreferencesNamespace, false)) {
    preferences.putUInt(kPasskeyKey, passkey);
    preferences.putBool(kPairOnBootKey, true);
    preferences.end();
  }
  if (wasGenerated != nullptr) *wasGenerated = true;
  return passkey;
}

static bool consumePairOnBoot() {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false)) return false;
  const bool enabled = preferences.getBool(kPairOnBootKey, false);
  if (enabled) preferences.remove(kPairOnBootKey);
  preferences.end();
  return enabled;
}

static bool storeProvisioning(const String& name, uint32_t passkey) {
  uint8_t identity[kBleIdentityBytes];
  generateBleIdentity(identity);
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false)) return false;
  const bool nameStored = preferences.putString(kBridgeNameKey, name) == name.length();
  const bool passkeyStored = preferences.putUInt(kPasskeyKey, passkey) == sizeof(uint32_t);
  const bool pairingStored = preferences.putBool(kPairOnBootKey, true) == sizeof(uint8_t);
  const bool identityStored = preferences.putBytes(
    kBleIdentityKey,
    identity,
    sizeof(identity)) == sizeof(identity);
  preferences.end();
  return nameStored && passkeyStored && pairingStored && identityStored;
}

static void setPairingWindow(bool enabled, uint32_t durationMs = 0) {
  gPairingWindowOpen = enabled;
  gPairingWindowOpenedAtMs = millis();
  gPairingWindowDurationMs = durationMs;
  NimBLEDevice::setSecurityPasskey(enabled ? gPasskey : gHiddenPasskey);
  Serial.printf("BLE pairing window %s.\n", enabled ? "open" : "closed");
}

static bool secureConnection(const NimBLEConnInfo& connInfo) {
  return connInfo.isBonded()
      && connInfo.isEncrypted()
      && connInfo.isAuthenticated()
      && connInfo.getSecKeySize() >= 16;
}

static void handleSerialCommand(String command) {
  command.trim();

  if (command == "INPUDECK GET-NAME") {
    Serial.printf("INPUDECK NAME %s\n", gBridgeName.c_str());
    return;
  }

  if (command == "INPUDECK GET-INFO") {
    Serial.printf("INPUDECK INFO SECURITY 1 IDENTITY 1 NAME %s\n", gBridgeName.c_str());
    return;
  }

  static const String provisionPrefix = "INPUDECK PROVISION ";
  if (command.startsWith(provisionPrefix)) {
    if (!gPairingWindowOpen) {
      Serial.println("INPUDECK ERROR physical pairing window is closed");
      return;
    }

    const String payload = command.substring(provisionPrefix.length());
    const int separator = payload.indexOf(' ');
    if (separator != 6) {
      Serial.println("INPUDECK ERROR PROVISION requires a six-digit passkey and name");
      return;
    }
    const String passkeyText = payload.substring(0, separator);
    for (size_t i = 0; i < passkeyText.length(); ++i) {
      if (!isDigit(passkeyText[i])) {
        Serial.println("INPUDECK ERROR passkey must contain six digits");
        return;
      }
    }
    const uint32_t passkey = static_cast<uint32_t>(passkeyText.toInt());
    String name = payload.substring(separator + 1);
    name.trim();
    if (!isValidPasskey(passkey) || !isValidBridgeName(name)) {
      Serial.println("INPUDECK ERROR invalid passkey or NAME");
      return;
    }
    if (!storeProvisioning(name, passkey)) {
      Serial.println("INPUDECK ERROR failed to save secure provisioning");
      return;
    }

    NimBLEDevice::deleteAllBonds();
    Serial.printf("INPUDECK OK PROVISION %s\n", name.c_str());
    Serial.flush();
    delay(150);
    ESP.restart();
    return;
  }

  static const String prefix = "INPUDECK SET-NAME ";
  if (!command.startsWith(prefix)) return;

  if (!gPairingWindowOpen) {
    Serial.println("INPUDECK ERROR physical provisioning window is closed");
    return;
  }

  String name = command.substring(prefix.length());
  name.trim();
  if (!isValidBridgeName(name)) {
    Serial.printf("INPUDECK ERROR NAME must be 1-%u UTF-8 bytes without control characters\n",
                  static_cast<unsigned>(kMaxBridgeNameBytes));
    return;
  }

  if (!storeBridgeName(name)) {
    Serial.println("INPUDECK ERROR failed to save NAME");
    return;
  }

  Serial.printf("INPUDECK OK NAME %s\n", name.c_str());
  Serial.flush();
  delay(150);
  ESP.restart();
}

static void processSerialCommands() {
  while (Serial.available() > 0) {
    const char byte = static_cast<char>(Serial.read());
    if (byte == '\n' || byte == '\r') {
      if (gSerialCommand.length() > 0) {
        handleSerialCommand(gSerialCommand);
        gSerialCommand = "";
      }
    } else if (gSerialCommand.length() < 96) {
      gSerialCommand += byte;
    } else {
      gSerialCommand = "";
    }
  }
}

// =====================
// Protocol Commands
// =====================

// ---- v1 (legacy): 3 bytes per frame ----
static const uint8_t CMD_KEY = 0x01;
static const uint8_t CMD_MOUSE_MOVE = 0x02;
static const uint8_t CMD_MOUSE_CLICK = 0x03;
static const uint8_t CMD_MOUSE_SCROLL = 0x04;

// ---- v2: [0xAA, 0x01] header + TLV frames ----
// Frame format: [cmd][len][payload...]
static const uint8_t V2_MAGIC = 0xAA;
static const uint8_t V2_VERSION = 0x01;

// Keyboard
static const uint8_t V2_SET_MODIFIERS = 0x01;  // payload: [mask]
static const uint8_t V2_KEY_DOWN = 0x02;       // payload: [keycode]
static const uint8_t V2_KEY_UP = 0x03;         // payload: [keycode]
static const uint8_t V2_KEY_TAP = 0x04;        // payload: [mask, keycode]

// Mouse
static const uint8_t V2_MOUSE_MOVE = 0x10;    // payload: [dx, dy]
static const uint8_t V2_MOUSE_SCROLL = 0x11;  // payload: [dx, dy]
static const uint8_t V2_MOUSE_CLICK = 0x12;   // payload: [button]
static const uint8_t V2_MOUSE_DOWN = 0x13;    // payload: [button]
static const uint8_t V2_MOUSE_UP = 0x14;      // payload: [button]

// Consumer Control. Usage is little-endian uint16 from HID Usage Page 0x0C.
static const uint8_t V2_CONSUMER_DOWN = 0x20; // payload: [usageLo, usageHi]
static const uint8_t V2_CONSUMER_UP = 0x21;   // payload: []

// USB-IF HUTRR110 System Microphone Mute (Generic Desktop usage 0xA9).
static const uint8_t V2_SYSTEM_MICROPHONE_MUTE_DOWN = 0x22; // payload: []
static const uint8_t V2_SYSTEM_MICROPHONE_MUTE_UP = 0x23;   // payload: []

// =====================
// USB HID instances
// =====================
USBHIDKeyboard Keyboard;
USBHIDMouse Mouse;
USBHIDConsumerControl ConsumerControl;
USBHID HidProbe;

static const uint8_t kSystemMicrophoneMuteDescriptor[] = {
  0x05, 0x01,       // Usage Page (Generic Desktop)
  0x09, 0x80,       // Usage (System Control)
  0xA1, 0x01,       // Collection (Application)
  0x85, HID_REPORT_ID_SYSTEM_CONTROL,
  0x09, 0xA9,       // Usage (System Microphone Mute)
  0x15, 0x00,       // Logical Minimum (0)
  0x25, 0x01,       // Logical Maximum (1)
  0x95, 0x01,       // Report Count (1)
  0x75, 0x01,       // Report Size (1)
  0x81, 0x06,       // Input (Data, Variable, Relative)
  0x75, 0x07,       // Report Size (7)
  0x81, 0x03,       // Input (Constant, Variable, Absolute)
  0x05, 0x08,       // Usage Page (LEDs)
  0x09, 0x57,       // Usage (System Microphone Mute)
  0x75, 0x01,       // Report Size (1)
  0x91, 0x06,       // Output (Data, Variable, Relative)
  0x75, 0x07,       // Report Size (7)
  0x91, 0x03,       // Output (Constant, Variable, Absolute)
  0xC0              // End Collection
};

class USBHIDSystemMicrophoneMute : public USBHIDDevice {
private:
  USBHID hid;

  bool send(uint8_t value) {
    return hid.SendReport(HID_REPORT_ID_SYSTEM_CONTROL, &value, 1);
  }

public:
  USBHIDSystemMicrophoneMute() : hid() {
    static bool initialized = false;
    if (!initialized) {
      initialized = true;
      USBHID::addDevice(this, sizeof(kSystemMicrophoneMuteDescriptor));
    }
  }

  void begin() {
    hid.begin();
  }

  size_t press() {
    return send(1) ? 1 : 0;
  }

  size_t release() {
    return send(0) ? 1 : 0;
  }

  uint16_t _onGetDescriptor(uint8_t* buffer) override {
    memcpy(buffer, kSystemMicrophoneMuteDescriptor, sizeof(kSystemMicrophoneMuteDescriptor));
    return sizeof(kSystemMicrophoneMuteDescriptor);
  }

  void _onOutput(uint8_t report_id, const uint8_t* buffer, uint16_t len) override {
    if (report_id != HID_REPORT_ID_SYSTEM_CONTROL || len == 0) return;
    Serial.printf("System microphone mute LED: %s\n", (buffer[0] & 0x01) ? "on" : "off");
  }
};

USBHIDSystemMicrophoneMute SystemMicrophoneMute;

// A warm reboot of some hosts leaves ESP32-S3 TinyUSB mounted but unable to
// deliver HID reports in pre-OS screens. A hardware reset recovers it, so do
// the same in software after a previously mounted USB host disappears or
// stops completing HID IN transfers.
static constexpr uint32_t kUsbRestartDelayMs = 250;
static constexpr uint32_t kHidProbeIntervalMs = 500;
static constexpr uint32_t kHidProbeTimeoutMs = 150;
static constexpr uint32_t kHidProbeQuietPeriodMs = 250;
static constexpr uint8_t kHidProbeFailureLimit = 2;
static volatile bool gUsbWasMounted = false;
static volatile bool gUsbMounted = false;
static volatile bool gUsbSuspended = false;
static volatile bool gUsbRestartRequested = false;
static volatile uint32_t gUsbStoppedAtMs = 0;
static volatile uint32_t gLastBleCommandAtMs = 0;
static volatile uint8_t gHidProbeFailures = 0;

enum class BridgeLedState : uint8_t {
  ready,
  usbOnly,
  bleOnly,
  powerOnly,
  pairing,
  usbError,
};

static BridgeLedState currentLedState() {
  if (gUsbRestartRequested) return BridgeLedState::usbError;
  if (gPairingWindowOpen) return BridgeLedState::pairing;
  if (gUsbMounted && gConnectedSecure) return BridgeLedState::ready;
  if (gUsbMounted) return BridgeLedState::usbOnly;
  if (gConnectedSecure) return BridgeLedState::bleOnly;
  return BridgeLedState::powerOnly;
}

static void writeStatusLed(uint8_t red, uint8_t green, uint8_t blue) {
#ifdef RGB_BUILTIN
  static uint8_t previousRed = 0xFF;
  static uint8_t previousGreen = 0xFF;
  static uint8_t previousBlue = 0xFF;
  if (red == previousRed && green == previousGreen && blue == previousBlue) return;
  previousRed = red;
  previousGreen = green;
  previousBlue = blue;
  // The tested ESP32-S3-Zero's onboard LED accepts GRB data even though the
  // Arduino-ESP32 Waveshare board profile declares RGB.
  rgbLedWriteOrdered(
      RGB_BUILTIN, LED_COLOR_ORDER_GRB, red, green, blue);
#else
  (void)red;
  (void)green;
  (void)blue;
#endif
}

static void updateStatusLed(uint32_t now) {
  switch (currentLedState()) {
    case BridgeLedState::ready:
      // Full path is ready: authenticated iPhone -> BLE -> USB HID host.
      writeStatusLed(0, 12, 2);
      break;

    case BridgeLedState::usbOnly:
      // A PC enumerated USB HID, but no authenticated iPhone is connected.
      // Keep enough green in the blue to distinguish it from pairing purple
      // on the tiny onboard LED without making it look like ready green.
      writeStatusLed(0, 8, 14);
      break;

    case BridgeLedState::bleOnly: {
      // The iPhone is connected, but USB supplies power without a data host.
      const uint32_t phase = now % 1600;
      const bool illuminated = phase < 130 || (phase >= 280 && phase < 410);
      writeStatusLed(illuminated ? 16 : 0, illuminated ? 5 : 0, 0);
      break;
    }

    case BridgeLedState::powerOnly:
      // Neither side is connected. A short red heartbeat confirms power.
      writeStatusLed((now % 2400) < 90 ? 10 : 0, 0, 0);
      break;

    case BridgeLedState::pairing: {
      // An unmistakable purple breath followed by a dark pause while a new
      // authenticated bond is physically allowed. The previous 2..12 range
      // never turned fully off and looked solid at the LED's low brightness.
      const uint32_t phase = now % 1600;
      const uint8_t level = phase < 500
        ? static_cast<uint8_t>(phase * 18 / 500)
        : phase < 1000
          ? static_cast<uint8_t>((1000 - phase) * 18 / 500)
          : 0;
      writeStatusLed(level, 0, level);
      break;
    }

    case BridgeLedState::usbError:
      writeStatusLed((now % 240) < 120 ? 18 : 0, 0, 0);
      break;
  }
}

static void requestUsbRecovery() {
  if (gUsbRestartRequested) return;

  gUsbStoppedAtMs = millis();
  gUsbRestartRequested = true;
}

static void usbEventCallback(
  void*,
  esp_event_base_t eventBase,
  int32_t eventId,
  void*) {
  if (eventBase != ARDUINO_USB_EVENTS) return;

  switch (eventId) {
    case ARDUINO_USB_STARTED_EVENT:
      gUsbWasMounted = true;
      gUsbMounted = true;
      gUsbSuspended = false;
      gHidProbeFailures = 0;
      Serial.println("USB mounted.");
      break;

    case ARDUINO_USB_STOPPED_EVENT:
      gUsbMounted = false;
      gUsbSuspended = false;
      Serial.println("USB unmounted.");
      if (gUsbWasMounted) {
        requestUsbRecovery();
      }
      break;

    case ARDUINO_USB_SUSPEND_EVENT:
      gUsbSuspended = true;
      Serial.println("USB suspended.");
      break;

    case ARDUINO_USB_RESUME_EVENT:
      gUsbSuspended = false;
      gHidProbeFailures = 0;
      Serial.println("USB resumed.");
      break;

    default:
      break;
  }
}

static uint8_t gModifiersMask = 0x00;
static bool gKeysDown[256] = { false };

static bool keyboardIsIdle() {
  if (gModifiersMask != 0) return false;

  for (bool keyDown : gKeysDown) {
    if (keyDown) return false;
  }
  return true;
}

static bool sendHidProbe() {
  hid_keyboard_report_t report = {};
  return HidProbe.SendReport(
    HID_REPORT_ID_KEYBOARD,
    &report,
    sizeof(report),
    kHidProbeTimeoutMs);
}

static void setModifiers(uint8_t newMask) {
  uint8_t diff = gModifiersMask ^ newMask;
  if (!diff) return;

  // Raw modifier codes: 0xE0..0xE7
  if (diff & 0x01) {
    if (newMask & 0x01) Keyboard.pressRaw(0xE0);
    else Keyboard.releaseRaw(0xE0);
  }  // LCtrl
  if (diff & 0x02) {
    if (newMask & 0x02) Keyboard.pressRaw(0xE1);
    else Keyboard.releaseRaw(0xE1);
  }  // LShift
  if (diff & 0x04) {
    if (newMask & 0x04) Keyboard.pressRaw(0xE2);
    else Keyboard.releaseRaw(0xE2);
  }  // LAlt
  if (diff & 0x08) {
    if (newMask & 0x08) Keyboard.pressRaw(0xE3);
    else Keyboard.releaseRaw(0xE3);
  }  // LGUI
  if (diff & 0x10) {
    if (newMask & 0x10) Keyboard.pressRaw(0xE4);
    else Keyboard.releaseRaw(0xE4);
  }  // RCtrl
  if (diff & 0x20) {
    if (newMask & 0x20) Keyboard.pressRaw(0xE5);
    else Keyboard.releaseRaw(0xE5);
  }  // RShift
  if (diff & 0x40) {
    if (newMask & 0x40) Keyboard.pressRaw(0xE6);
    else Keyboard.releaseRaw(0xE6);
  }  // RAlt
  if (diff & 0x80) {
    if (newMask & 0x80) Keyboard.pressRaw(0xE7);
    else Keyboard.releaseRaw(0xE7);
  }  // RGUI

  gModifiersMask = newMask;
}

static void keyDown(uint8_t keycode) {
  if (keycode == 0x00) return;
  if (gKeysDown[keycode]) return;
  Keyboard.pressRaw(keycode);
  gKeysDown[keycode] = true;
}

static void keyUp(uint8_t keycode) {
  if (keycode == 0x00) return;
  if (!gKeysDown[keycode]) return;
  Keyboard.releaseRaw(keycode);
  gKeysDown[keycode] = false;
}

static void keyTap(uint8_t modifiersMask, uint8_t keycode) {
  if (keycode == 0x00) return;

  bool wasDown = gKeysDown[keycode];
  uint8_t savedMods = gModifiersMask;

  setModifiers(modifiersMask);

  if (!wasDown) {
    keyDown(keycode);
    delay(5);
    keyUp(keycode);
    delay(1);
  }

  setModifiers(savedMods);
}

// v1 compatibility shim
static void sendKeyPressAndRelease(uint8_t modifiers, uint8_t keycode) {
  keyTap(modifiers, keycode);
}

static void sendMouseMove(int8_t dx, int8_t dy) {
  Mouse.move(dx, dy);
}

static void sendMouseClick(uint8_t button) {
  // button: 1=left, 2=right, 4=middle
  Mouse.click(button);
}

static void sendMouseButtonDown(uint8_t button) {
  Mouse.press(button);
}

static void sendMouseButtonUp(uint8_t button) {
  Mouse.release(button);
}

static void sendMouseScroll(int8_t dx, int8_t dy) {
  // Scroll: positive Y = scroll up, negative Y = scroll down
  Mouse.move(0, 0, dy, dx);
}

static void sendConsumerDown(uint16_t usage) {
  ConsumerControl.press(usage);
}

static void sendConsumerUp() {
  ConsumerControl.release();
}

static void sendSystemMicrophoneMuteDown() {
  SystemMicrophoneMute.press();
}

static void sendSystemMicrophoneMuteUp() {
  SystemMicrophoneMute.release();
}

// =====================
// BLE GATT server
// =====================
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pWriteChar = nullptr;
NimBLECharacteristic* pSecurityChar = nullptr;
NimBLECharacteristic* pNameChar = nullptr;

static void disconnectPeer(uint16_t connHandle) {
  if (connHandle == gConnectedHandle) {
    gConnectedHandle = BLE_HS_CONN_HANDLE_NONE;
    gConnectedWasBonded = false;
    gConnectedSecure = false;
    gConnectionSecurityStarted = false;
    gConnectedAtMs = 0;
  }
  pServer->disconnect(connHandle);
}

class WriteCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override {
    if (!secureConnection(connInfo)) {
      Serial.println("Rejected HID command from an unauthenticated BLE connection.");
      disconnectPeer(connInfo.getConnHandle());
      return;
    }

    gLastBleCommandAtMs = millis();

    std::string v = pCharacteristic->getValue();
    if (v.size() < 3) return;

    // ---- v2: [0xAA, 0x01] + TLV frames ----
    if ((uint8_t)v[0] == V2_MAGIC && (uint8_t)v[1] == V2_VERSION) {
      size_t idx = 2;

      while (idx + 1 < v.size()) {
        uint8_t cmd = (uint8_t)v[idx + 0];
        uint8_t len = (uint8_t)v[idx + 1];
        idx += 2;

        if (idx + len > v.size()) break;

        const uint8_t* payload = (const uint8_t*)&v[idx];

        switch (cmd) {
          case V2_SET_MODIFIERS:
            if (len == 1) setModifiers(payload[0]);
            break;

          case V2_KEY_DOWN:
            if (len == 1) keyDown(payload[0]);
            break;

          case V2_KEY_UP:
            if (len == 1) keyUp(payload[0]);
            break;

          case V2_KEY_TAP:
            if (len == 2) keyTap(payload[0], payload[1]);
            break;

          case V2_MOUSE_MOVE:
            if (len == 2) sendMouseMove((int8_t)payload[0], (int8_t)payload[1]);
            break;

          case V2_MOUSE_SCROLL:
            if (len == 2) sendMouseScroll((int8_t)payload[0], (int8_t)payload[1]);
            break;

          case V2_MOUSE_CLICK:
            if (len == 1) sendMouseClick(payload[0]);
            break;

          case V2_MOUSE_DOWN:
            if (len == 1) sendMouseButtonDown(payload[0]);
            break;

          case V2_MOUSE_UP:
            if (len == 1) sendMouseButtonUp(payload[0]);
            break;

          case V2_CONSUMER_DOWN:
            if (len == 2) {
              uint16_t usage = (uint16_t)payload[0] | ((uint16_t)payload[1] << 8);
              sendConsumerDown(usage);
            }
            break;

          case V2_CONSUMER_UP:
            if (len == 0) sendConsumerUp();
            break;

          case V2_SYSTEM_MICROPHONE_MUTE_DOWN:
            if (len == 0) sendSystemMicrophoneMuteDown();
            break;

          case V2_SYSTEM_MICROPHONE_MUTE_UP:
            if (len == 0) sendSystemMicrophoneMuteUp();
            break;

          default:
            break;
        }

        idx += len;
      }

      return;
    }

    // ---- v1: 3-byte frames (supports batching) ----
    for (size_t i = 0; i + 2 < v.size(); i += 3) {
      uint8_t type = (uint8_t)v[i + 0];
      uint8_t byte1 = (uint8_t)v[i + 1];
      uint8_t byte2 = (uint8_t)v[i + 2];

      switch (type) {
        case CMD_KEY:
          sendKeyPressAndRelease(byte1, byte2);
          break;

        case CMD_MOUSE_MOVE:
          sendMouseMove((int8_t)byte1, (int8_t)byte2);
          break;

        case CMD_MOUSE_CLICK:
          sendMouseClick(byte1);
          break;

        case CMD_MOUSE_SCROLL:
          sendMouseScroll((int8_t)byte1, (int8_t)byte2);
          break;

        default:
          break;
      }
    }
  }
};

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    gConnectedHandle = connInfo.getConnHandle();
    gConnectedAtMs = millis();
    gConnectedWasBonded = connInfo.isBonded()
      || NimBLEDevice::isBonded(connInfo.getIdAddress());
    gConnectedSecure = secureConnection(connInfo);
    gConnectionSecurityStarted = false;
    if (gConnectedWasBonded && !gConnectedSecure) {
      gConnectionSecurityStarted = NimBLEDevice::startSecurity(connInfo.getConnHandle());
    }
    Serial.print("BLE connected: ");
    Serial.println(connInfo.getAddress().toString().c_str());
  }

  void onIdentity(NimBLEConnInfo& connInfo) override {
    if (connInfo.getConnHandle() == gConnectedHandle) {
      gConnectedWasBonded = gConnectedWasBonded
        || NimBLEDevice::isBonded(connInfo.getIdAddress());
      if (gConnectedWasBonded && !gConnectedSecure && !gConnectionSecurityStarted) {
        gConnectionSecurityStarted = NimBLEDevice::startSecurity(connInfo.getConnHandle());
      }
    }
  }

  uint32_t onPassKeyDisplay() override {
    return gPairingWindowOpen ? gPasskey : gHiddenPasskey;
  }

  void onAuthenticationComplete(NimBLEConnInfo& connInfo) override {
    if (!secureConnection(connInfo)) {
      Serial.println("BLE authentication rejected: bonding, MITM, Secure Connections, and a 128-bit key are required.");
      if (!gPairingWindowOpen) {
        // A closed window has no usable passkey. Rotate the undisclosed decoy
        // after every failed attempt so repeated guesses cannot accumulate.
        gHiddenPasskey = generatePasskey();
        NimBLEDevice::setSecurityPasskey(gHiddenPasskey);
      }
      disconnectPeer(connInfo.getConnHandle());
      return;
    }

    Serial.print("BLE authenticated and bonded: ");
    Serial.println(connInfo.getIdAddress().toString().c_str());
    gConnectedSecure = true;
    if (gPairingWindowOpen && !gConnectedWasBonded) setPairingWindow(false);
  }

  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    Serial.print("BLE disconnected, reason=");
    Serial.println(reason);

    if (connInfo.getConnHandle() == gConnectedHandle) {
      gConnectedHandle = BLE_HS_CONN_HANDLE_NONE;
      gConnectedWasBonded = false;
      gConnectedSecure = false;
      gConnectionSecurityStarted = false;
      gConnectedAtMs = 0;
    }

    NimBLEDevice::startAdvertising();
  }
};

static void setupBle() {
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
  NimBLEDevice::setSecurityPasskey(gPairingWindowOpen ? gPasskey : gHiddenPasskey);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  pServer->advertiseOnDisconnect(true);

  NimBLEService* svc = pServer->createService(kServiceUUID);

  pWriteChar = svc->createCharacteristic(
    kWriteCharUUID,
    NIMBLE_PROPERTY::WRITE
      | NIMBLE_PROPERTY::WRITE_NR
      | NIMBLE_PROPERTY::WRITE_ENC
      | NIMBLE_PROPERTY::WRITE_AUTHEN);
  pWriteChar->setCallbacks(new WriteCallbacks());

  pSecurityChar = svc->createCharacteristic(
    kSecurityCharUUID,
    NIMBLE_PROPERTY::READ
      | NIMBLE_PROPERTY::READ_ENC
      | NIMBLE_PROPERTY::READ_AUTHEN);
  pSecurityChar->setValue(kSecurityCapability, sizeof(kSecurityCapability));

  // The GAP name reported by phones may be stale after a reflash. Expose the
  // stored UTF-8 name through the authenticated connection as the authoritative
  // app label while keeping the security capability payload backward-compatible.
  pNameChar = svc->createCharacteristic(
    kNameCharUUID,
    NIMBLE_PROPERTY::READ
      | NIMBLE_PROPERTY::READ_ENC
      | NIMBLE_PROPERTY::READ_AUTHEN);
  pNameChar->setValue(
    reinterpret_cast<const uint8_t*>(gBridgeName.c_str()),
    gBridgeName.length());

  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(kServiceUUID);
  adv->enableScanResponse(true);
  adv->setName(gBridgeName.c_str());
  adv->start();

  Serial.printf("BLE advertising started as %s.\n", gBridgeName.c_str());
}

static void setupUsbHid() {
  USB.onEvent(usbEventCallback);
  Keyboard.begin();
  Mouse.begin();
  ConsumerControl.begin();
  SystemMicrophoneMute.begin();
  HidProbe.begin();
  USB.begin();

  Serial.println("USB HID Keyboard, Mouse, Consumer Control & System Microphone Mute started.");
}

void setup() {
  Serial.begin(115200);
  delay(200);

  gBridgeName = loadBridgeName();
  // Initialize the Bluetooth controller before drawing passkeys so esp_random
  // has the RF entropy source available, including for manual source uploads.
  NimBLEDevice::init(gBridgeName.c_str());
  gHasBleIdentity = loadBleIdentity(gBleIdentity);
  if (gHasBleIdentity) {
    const bool addressSet = NimBLEDevice::setOwnAddr(gBleIdentity);
    const bool typeSet = addressSet && NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM);
    if (!typeSet) {
      Serial.println("ERROR: failed to restore the provisioned BLE identity.");
      gHasBleIdentity = false;
    }
  }
  bool generatedPasskey = false;
  gPasskey = loadPasskey(&generatedPasskey);
  gHiddenPasskey = generatePasskey();
  const bool pairOnBoot = consumePairOnBoot() || generatedPasskey;
  gPairingWindowOpen = pairOnBoot;
  gPairingWindowOpenedAtMs = millis();
  gPairingWindowDurationMs = pairOnBoot ? kProvisionedPairingWindowMs : 0;
  pinMode(kPairButtonPin, INPUT_PULLUP);
  Serial.println("Starting InpuDeck ESP32-S3 BLE -> USB HID bridge...");
  if (generatedPasskey) {
    Serial.printf("INPUDECK GENERATED PASSKEY %06lu\n", static_cast<unsigned long>(gPasskey));
  }

  setupUsbHid();
  setupBle();
  Serial.printf(
    "INPUDECK READY SECURITY 1 IDENTITY %u PAIRING %s NAME %s\n",
    gHasBleIdentity ? 1 : 0,
    gPairingWindowOpen ? "OPEN" : "CLOSED",
    gBridgeName.c_str());
}

void loop() {
  static uint32_t lastHidProbeAtMs = 0;

  processSerialCommands();

  const uint32_t now = millis();
  const bool pairButtonPressed = digitalRead(kPairButtonPin) == LOW;
  if (pairButtonPressed && !gPairButtonDown) {
    gPairButtonDown = true;
    gPairButtonHandled = false;
    gPairButtonDownAtMs = now;
  } else if (pairButtonPressed && gPairButtonDown && !gPairButtonHandled
             && (uint32_t)(now - gPairButtonDownAtMs) >= kBondResetHoldMs) {
    gPairButtonHandled = true;
    NimBLEDevice::deleteAllBonds();
    setPairingWindow(true, kPairingWindowMs);
    if (gConnectedHandle != BLE_HS_CONN_HANDLE_NONE) {
      disconnectPeer(gConnectedHandle);
    } else {
      NimBLEDevice::startAdvertising();
    }
    Serial.println("All BLE bonds deleted; pairing is open for two minutes.");
  } else if (!pairButtonPressed && gPairButtonDown) {
    const uint32_t heldMs = now - gPairButtonDownAtMs;
    gPairButtonDown = false;
    if (!gPairButtonHandled && heldMs >= kPairButtonHoldMs) {
      setPairingWindow(true, kPairingWindowMs);
      if (gConnectedHandle != BLE_HS_CONN_HANDLE_NONE) {
        disconnectPeer(gConnectedHandle);
      } else {
        NimBLEDevice::startAdvertising();
      }
      Serial.println("Pairing is open for two minutes.");
    }
  }

  if (gPairingWindowOpen
      && gPairingWindowDurationMs > 0
      && (uint32_t)(now - gPairingWindowOpenedAtMs) >= gPairingWindowDurationMs) {
    setPairingWindow(false);
  }

  if (gConnectedHandle != BLE_HS_CONN_HANDLE_NONE && !gConnectedSecure) {
    const uint32_t connectedForMs = now - gConnectedAtMs;
    if (!gPairingWindowOpen
        && !gConnectionSecurityStarted
        && connectedForMs >= kBondIdentityGraceMs) {
      NimBLEConnInfo connInfo = pServer->getPeerInfoByHandle(gConnectedHandle);
      gConnectedWasBonded = connInfo.isBonded()
        || NimBLEDevice::isBonded(connInfo.getIdAddress());
      if (gConnectedWasBonded) {
        gConnectionSecurityStarted = NimBLEDevice::startSecurity(gConnectedHandle);
      } else {
        Serial.println("Rejected unknown BLE peer while the pairing window is closed.");
        disconnectPeer(gConnectedHandle);
      }
    } else if ((!gPairingWindowOpen && connectedForMs >= kAuthenticationTimeoutMs)
               || (gPairingWindowOpen && connectedForMs >= kEnrollmentConnectionTimeoutMs)) {
      Serial.println("Disconnected BLE peer that did not complete authentication in time.");
      disconnectPeer(gConnectedHandle);
    }
  }

  updateStatusLed(now);

  if (!gUsbRestartRequested
      && gUsbMounted
      && !gUsbSuspended
      && keyboardIsIdle()
      && (uint32_t)(millis() - gLastBleCommandAtMs) >= kHidProbeQuietPeriodMs
      && (uint32_t)(millis() - lastHidProbeAtMs) >= kHidProbeIntervalMs) {
    lastHidProbeAtMs = millis();

    if (sendHidProbe()) {
      gHidProbeFailures = 0;
    } else {
      ++gHidProbeFailures;
      Serial.printf(
        "HID probe failed (%u/%u).\n",
        (unsigned)gHidProbeFailures,
        (unsigned)kHidProbeFailureLimit);

      if (gHidProbeFailures >= kHidProbeFailureLimit) {
        requestUsbRecovery();
      }
    }
  }

  if (gUsbRestartRequested
      && (uint32_t)(millis() - gUsbStoppedAtMs) >= kUsbRestartDelayMs) {
    Serial.println("Restarting ESP32-S3 to recover USB HID...");
    delay(20);
    ESP.restart();
  }

  delay(20);
}
