// ESP32-S3 iPhone bridge (v3): pretends to be a watch for the iPhone; native USB = serial + keyboard.
//  BLE  : ANCS notifications, AMS media, battery, link RSSI
//  USB  : CDC serial to the Mac app + HID keyboard / media keys
//  WiFi : when the Mac app is silent (no heartbeat 30 s) forward notifications to Telegram
//  LED  : call > Claude waiting > unread > Claude done > Claude working
//
// Serial out (JSON lines): n d m bat r btn s wifi fwd
// Serial in:
//   A <uid> <0|1>      ANCS action          M <cmd>         AMS command
//   L <r> <g> <b>      LED override         C <0..3>        Claude: 0 off 1 working 2 waiting 3 done
//   R <uid>            drop from unread     K <mods> <key>  key combo (mods: 1 ctrl 2 shift 4 alt 8 cmd)
//   CC <usage>         consumer key (hex)   HB              heartbeat from Mac app
//   W <ssid>\t<pass>   save Wi-Fi           TG <token>\t<chat>  save Telegram
//   MUTE a,b,c         bundle ids not to forward              TGTEST  PING  UNPAIR
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <FS.h>
#include <USB.h>
#include <USBHIDKeyboard.h>
#include <USBHIDConsumerControl.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <vector>

static const NimBLEUUID ANCS_SVC("7905F431-B5CE-4E99-A40F-4B1E122D00D0");
static const NimBLEUUID ANCS_NS ("9FBF120D-6301-42D9-8C58-25E699A21DBD");
static const NimBLEUUID ANCS_CP ("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9");
static const NimBLEUUID ANCS_DS ("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB");
static const NimBLEUUID AMS_SVC ("89D3502B-0F36-433A-8EF4-C502AD55F8DC");
static const NimBLEUUID AMS_RC  ("9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2");
static const NimBLEUUID AMS_EU  ("2F7CABCE-808D-411F-9A0C-BB92BA96C102");

#define LED_PIN 48
#define BTN_PIN 0

USBHIDKeyboard Keyboard;
USBHIDConsumerControl Consumer;
Preferences prefs;

struct NsEvent { uint8_t event, flags, cat; uint32_t uid; };
struct Unread  { uint32_t uid; uint8_t kind; };

static NimBLEServer* server;
static NimBLEClient* cli = nullptr;
static NimBLERemoteCharacteristic* cp = nullptr;
static NimBLERemoteCharacteristic* amsRc = nullptr;
static QueueHandle_t nsQueue, outQueue, fwdQueue;
static portMUX_TYPE dsMux = portMUX_INITIALIZER_UNLOCKED;
static std::vector<uint8_t> dsBuf;
static volatile bool dsDirty = false;

static volatile bool needSetup = false;
static volatile uint16_t connHandle = BLE_HS_CONN_HANDLE_NONE;
static volatile bool ancsReady = false;
static uint32_t setupAt = 0; static int setupTries = 0;
static uint32_t retrySecAt = 0;

static std::vector<NsEvent> fetchQ;
static uint8_t catOf[256]; static uint32_t uidOf[256];
static bool inFlight = false; static uint32_t inFlightUid = 0, inFlightAt = 0;

static std::vector<Unread> unread;
static uint32_t callUid = 0; static bool callActive = false;
static bool ledOverride = false; static uint8_t ovR, ovG, ovB;
static uint8_t claudeMode = 0;

static uint32_t lastHB = 0;                 // last heartbeat from the Mac app
static String wifiSsid, wifiPass, tgToken, tgChat, muteList;
static bool macAlive() { return lastHB && millis() - lastHB < 30000; }

static void led(uint8_t r, uint8_t g, uint8_t b) { neopixelWrite(LED_PIN, r, g, b); }

static String jesc(const std::string& s) {
  String o; o.reserve(s.size() + 8);
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break; case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break; case '\r': break; case '\t': o += "\\t"; break;
      default: if (c < 0x20) o += ' '; else o += (char)c;
    }
  }
  return o;
}
static void status(const char* s) { Serial.printf("{\"t\":\"s\",\"s\":\"%s\"}\n", s); }
static void pushOut(const String& s) { char* p = strdup(s.c_str()); if (xQueueSend(outQueue, &p, 0) != pdTRUE) free(p); }

// ---------- BLE callbacks ----------
static void onNS(NimBLERemoteCharacteristic*, uint8_t* d, size_t n, bool) {
  if (n < 8) return;
  NsEvent e{d[0], d[1], d[2], (uint32_t)d[4] | (uint32_t)d[5] << 8 | (uint32_t)d[6] << 16 | (uint32_t)d[7] << 24};
  xQueueSend(nsQueue, &e, 0);
}
static void onDS(NimBLERemoteCharacteristic*, uint8_t* d, size_t n, bool) {
  portENTER_CRITICAL(&dsMux); dsBuf.insert(dsBuf.end(), d, d + n); dsDirty = true; portEXIT_CRITICAL(&dsMux);
}
static void onBattery(NimBLERemoteCharacteristic*, uint8_t* d, size_t n, bool) {
  if (n >= 1) pushOut(String("{\"t\":\"bat\",\"v\":") + d[0] + "}");
}
static void onAmsEU(NimBLERemoteCharacteristic*, uint8_t* d, size_t n, bool) {
  if (n < 3) return;
  std::string v((const char*)d + 3, n - 3);
  pushOut(String("{\"t\":\"m\",\"e\":") + d[0] + ",\"a\":" + d[1] + ",\"v\":\"" + jesc(v) + "\"}");
}

class ServerCB : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo& ci) override {
    connHandle = ci.getConnHandle(); pushOut("{\"t\":\"s\",\"s\":\"connected\"}");
    retrySecAt = millis() + 20000;
  }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
    connHandle = BLE_HS_CONN_HANDLE_NONE; ancsReady = false; cp = nullptr; amsRc = nullptr; cli = nullptr; needSetup = false;
    pushOut(String("{\"t\":\"s\",\"s\":\"disconnected\",\"reason\":") + reason + "}");
  }
  void onAuthenticationComplete(NimBLEConnInfo& ci) override {
    if (ci.isEncrypted()) { retrySecAt = 0; pushOut("{\"t\":\"s\",\"s\":\"encrypted\"}"); needSetup = true; setupTries = 0; setupAt = millis() + 300; }
    else { pushOut("{\"t\":\"s\",\"s\":\"auth_failed\"}"); retrySecAt = millis() + 20000; }
  }
};

// ---------- iPhone services ----------
static void setupExtras() {
  if (auto bs = cli->getService(NimBLEUUID((uint16_t)0x180F))) {
    if (auto bl = bs->getCharacteristic(NimBLEUUID((uint16_t)0x2A19))) {
      NimBLEAttValue v = bl->readValue();
      if (v.size()) Serial.printf("{\"t\":\"bat\",\"v\":%u}\n", v.data()[0]);
      if (bl->canNotify()) bl->subscribe(true, onBattery, true);
    }
  }
  if (auto as = cli->getService(AMS_SVC)) {
    amsRc = as->getCharacteristic(AMS_RC);
    auto eu = as->getCharacteristic(AMS_EU);
    if (eu && eu->subscribe(true, onAmsEU, true)) {
      uint8_t track[] = {2, 0, 2}, player[] = {0, 0, 1};
      eu->writeValue(track, sizeof(track), true);
      eu->writeValue(player, sizeof(player), true);
      status("ams_ready");
    }
  }
}

static void trySetupANCS() {
  cli = server->getClient(connHandle);
  if (!cli) { status("no_client"); return; }
  NimBLERemoteService* s = cli->getService(ANCS_SVC);
  if (!s) { status("ancs_not_found_retry"); setupAt = millis() + 2000; return; }
  auto ns = s->getCharacteristic(ANCS_NS);
  auto ds = s->getCharacteristic(ANCS_DS);
  cp = s->getCharacteristic(ANCS_CP);
  if (!ns || !ds || !cp) { status("ancs_chars_missing"); setupAt = millis() + 2000; return; }
  if (!ds->subscribe(true, onDS, true) || !ns->subscribe(true, onNS, true)) { status("subscribe_failed_retry"); setupAt = millis() + 2000; return; }
  needSetup = false; ancsReady = true;
  status("ancs_ready");
  setupExtras();
}

static void requestAttrs(uint32_t uid) {
  uint8_t cmd[] = {0x00, (uint8_t)uid, (uint8_t)(uid >> 8), (uint8_t)(uid >> 16), (uint8_t)(uid >> 24),
                   0x00, 0x01, 0x40, 0x00, 0x02, 0x40, 0x00, 0x03, 0x00, 0x01};
  portENTER_CRITICAL(&dsMux); dsBuf.clear(); portEXIT_CRITICAL(&dsMux);
  inFlight = true; inFlightUid = uid; inFlightAt = millis();
  if (!cp || !cp->writeValue(cmd, sizeof(cmd), true)) inFlight = false;
}

// ---------- Telegram forwarding (own task: HTTPS is slow) ----------
static const char* appLabel(const std::string& b) {
  if (b == "com.tencent.xin") return "微信";
  if (b == "com.apple.MobileSMS") return "信息";
  if (b == "com.apple.mobilephone" || b == "com.apple.InCallService") return "电话";
  if (b == "com.tencent.mqq") return "QQ";
  if (b == "com.tencent.ww") return "企业微信";
  if (b == "com.apple.mobilemail") return "邮件";
  return nullptr;
}
static String urlJsonEsc(const String& s) { return jesc(std::string(s.c_str())); }

static void fwdTask(void*) {
  for (;;) {
    char* p;
    if (xQueueReceive(fwdQueue, &p, portMAX_DELAY) != pdTRUE) continue;
    String text(p); free(p);
    if (tgToken.isEmpty() || tgChat.isEmpty()) { pushOut("{\"t\":\"fwd\",\"ok\":false,\"err\":\"no_telegram\"}"); continue; }
    if (WiFi.status() != WL_CONNECTED) {
      if (wifiSsid.isEmpty()) { pushOut("{\"t\":\"fwd\",\"ok\":false,\"err\":\"no_wifi\"}"); continue; }
      WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
      for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) vTaskDelay(pdMS_TO_TICKS(250));
    }
    if (WiFi.status() != WL_CONNECTED) { pushOut("{\"t\":\"fwd\",\"ok\":false,\"err\":\"wifi_failed\"}"); continue; }
    WiFiClientSecure tls; tls.setInsecure();
    HTTPClient http;
    http.setTimeout(8000);
    http.begin(tls, "https://api.telegram.org/bot" + tgToken + "/sendMessage");
    http.addHeader("Content-Type", "application/json");
    int code = http.POST("{\"chat_id\":\"" + tgChat + "\",\"text\":\"" + urlJsonEsc(text) + "\"}");
    http.end();
    pushOut(String("{\"t\":\"fwd\",\"ok\":") + (code == 200 ? "true" : "false") + ",\"http\":" + code + "}");
  }
}
static void queueForward(const String& text) {
  char* p = strdup(text.c_str());
  if (xQueueSend(fwdQueue, &p, 0) != pdTRUE) free(p);
}

static void parseDS() {
  std::vector<uint8_t> b;
  portENTER_CRITICAL(&dsMux); b = dsBuf; dsDirty = false; portEXIT_CRITICAL(&dsMux);
  if (b.size() < 5 || b[0] != 0x00) return;
  uint32_t uid = b[1] | b[2] << 8 | b[3] << 16 | (uint32_t)b[4] << 24;
  std::string attr[4]; size_t i = 5; int got = 0;
  while (got < 4) {
    if (i + 3 > b.size()) return;
    uint8_t id = b[i]; size_t len = b[i + 1] | b[i + 2] << 8;
    if (i + 3 + len > b.size()) return;
    if (id < 4) attr[id].assign((const char*)&b[i + 3], len);
    i += 3 + len; got++;
  }
  portENTER_CRITICAL(&dsMux); dsBuf.clear(); portEXIT_CRITICAL(&dsMux);
  uint8_t slot = uid & 0xFF; uint8_t cat = uidOf[slot] == uid ? catOf[slot] : 0;
  Serial.printf("{\"t\":\"n\",\"uid\":%lu,\"cat\":%u,\"app\":\"%s\",\"title\":\"%s\",\"sub\":\"%s\",\"msg\":\"%s\"}\n",
                (unsigned long)uid, cat, jesc(attr[0]).c_str(), jesc(attr[1]).c_str(),
                jesc(attr[2]).c_str(), jesc(attr[3]).c_str());
  if (uid == inFlightUid) inFlight = false;
  uint8_t kind = 0;
  if (cat == 1) { kind = 3; callUid = uid; callActive = true; }
  else if (attr[0] == "com.apple.MobileSMS") kind = 2;
  else if (attr[0] == "com.tencent.xin") kind = 1;
  if (cat != 2) unread.push_back({uid, kind});

  // Mac app not listening → forward
  bool muted = muteList.length() && (("," + muteList + ",").indexOf(String(",") + attr[0].c_str() + ",") >= 0);
  if (!macAlive() && !muted) {
    const char* lbl = appLabel(attr[0]);
    String head = cat == 1 ? String("📞 来电：") + attr[1].c_str()
                           : String(lbl ? lbl : attr[0].c_str()) + " · " + attr[1].c_str();
    String body = attr[3].c_str();
    if (attr[2].size()) body = String(attr[2].c_str()) + " — " + body;
    queueForward(head + "\n" + body);
  }
}

static void removeUnread(uint32_t uid) {
  for (size_t i = 0; i < unread.size(); i++) if (unread[i].uid == uid) { unread.erase(unread.begin() + i); break; }
  if (callActive && uid == callUid) callActive = false;
}

// ---------- LED ----------
static void updateLed() {
  uint32_t now = millis();
  if (ledOverride) { led(ovR, ovG, ovB); return; }
  if (connHandle == BLE_HS_CONN_HANDLE_NONE || !ancsReady) {
    if (claudeMode == 2) { led((now / 300) % 2 ? 40 : 0, 0, (now / 300) % 2 ? 50 : 0); return; }
    led(0, 0, (now % 1500) < 40 ? 20 : 0); return;
  }
  uint8_t top = 0; bool any = !unread.empty();
  for (auto& u : unread) if (u.kind > top) top = u.kind;
  float k = 0.35f + 0.65f * (0.5f + 0.5f * sinf(now / 600.0f));
  if (callActive || top == 3) { led((now / 250) % 2 ? 60 : 0, 0, 0); return; }
  if (claudeMode == 2) { led((now / 300) % 2 ? 40 : 0, 0, (now / 300) % 2 ? 50 : 0); return; }   // purple blink
  if (any) {
    switch (top) {
      case 2: led(0, 0, (uint8_t)(30 * k)); return;
      case 1: led(0, (uint8_t)(30 * k), 0); return;
      default: led((uint8_t)(18 * k), (uint8_t)(18 * k), (uint8_t)(18 * k)); return;
    }
  }
  if (claudeMode == 3) { led((uint8_t)(30 * k), 0, (uint8_t)(38 * k)); return; }                // purple breathe
  if (claudeMode == 1) { float s = 0.5f + 0.5f * sinf(now / 1500.0f); led(0, (uint8_t)(4 + 10 * s), (uint8_t)(6 + 14 * s)); return; } // dim cyan
  led(0, 0, 0);
}

// ---------- actions ----------
static void ancsAction(uint32_t uid, uint8_t act) {
  if (!cp) return;
  uint8_t cmd[] = {0x02, (uint8_t)uid, (uint8_t)(uid >> 8), (uint8_t)(uid >> 16), (uint8_t)(uid >> 24), act};
  cp->writeValue(cmd, sizeof(cmd), true);
}
static void amsCmd(uint8_t c) { if (amsRc) amsRc->writeValue(&c, 1, true); }

static void keyCombo(int mods, int key) {
  if (mods & 1) Keyboard.press(KEY_LEFT_CTRL);
  if (mods & 2) Keyboard.press(KEY_LEFT_SHIFT);
  if (mods & 4) Keyboard.press(KEY_LEFT_ALT);
  if (mods & 8) Keyboard.press(KEY_LEFT_GUI);
  if (key) Keyboard.press(key);
  delay(30);
  Keyboard.releaseAll();
}
static void consumerKey(uint16_t usage) { Consumer.press(usage); delay(30); Consumer.release(); }

// ---------- BOOT button ----------
static void onButton(const char* k) {
  Serial.printf("{\"t\":\"btn\",\"k\":\"%s\"}\n", k);
  if (macAlive()) return;                         // Mac app decides what each gesture does
  if (!strcmp(k, "long")) { if (callActive) ancsAction(callUid, 1); else amsCmd(2); }
  else if (!strcmp(k, "double")) amsCmd(3);
  else if (!strcmp(k, "single")) { unread.clear(); claudeMode = claudeMode == 1 ? 1 : 0; }
}
static void pollButton() {
  static bool last = true; static uint32_t downAt = 0, upAt = 0; static int clicks = 0; static bool longFired = false;
  bool cur = digitalRead(BTN_PIN);
  uint32_t now = millis();
  if (cur != last) {
    delay(15); cur = digitalRead(BTN_PIN); if (cur == last) return;
    last = cur;
    if (!cur) { downAt = now; longFired = false; }
    else if (!longFired) { clicks++; upAt = now; }
  }
  if (!cur && !longFired && now - downAt > 700) { longFired = true; clicks = 0; onButton("long"); }
  if (clicks && cur && now - upAt > 350) { onButton(clicks >= 3 ? "triple" : clicks == 2 ? "double" : "single"); clicks = 0; }
}

// ---------- Wi-Fi ----------
static void wifiStart() {
  if (wifiSsid.isEmpty()) return;
  WiFi.mode(WIFI_STA); WiFi.setAutoReconnect(true);
  WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
}
static void reportWifi() {
  static int lastSt = -1;
  int st = wifiSsid.isEmpty() ? -2 : (int)WiFi.status();
  if (st == lastSt) return;
  lastSt = st;
  if (st == -2) Serial.println("{\"t\":\"wifi\",\"s\":\"unset\"}");
  else if (st == WL_CONNECTED) Serial.printf("{\"t\":\"wifi\",\"s\":\"connected\",\"ip\":\"%s\",\"rssi\":%d}\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
  else Serial.printf("{\"t\":\"wifi\",\"s\":\"connecting\",\"code\":%d}\n", st);
}

// ---------- serial commands ----------
static void handleLine(String line) {
  line.trim();
  unsigned long uid; int a, r, g, b;
  if (line == "HB") { lastHB = millis(); return; }
  if (line == "U") { unread.clear(); return; }
  if (line.startsWith("A ") && sscanf(line.c_str() + 2, "%lu %d", &uid, &a) == 2) { ancsAction(uid, a); return; }
  if (line.startsWith("M ") && sscanf(line.c_str() + 2, "%d", &a) == 1) { amsCmd(a); return; }
  if (line.startsWith("L ") && sscanf(line.c_str() + 2, "%d %d %d", &r, &g, &b) == 3) { ledOverride = (r || g || b); ovR = r; ovG = g; ovB = b; return; }
  if (line.startsWith("C ") && sscanf(line.c_str() + 2, "%d", &a) == 1) { claudeMode = a; return; }
  if (line.startsWith("R ") && sscanf(line.c_str() + 2, "%lu", &uid) == 1) { removeUnread(uid); return; }
  if (line.startsWith("K ") && sscanf(line.c_str() + 2, "%d %d", &a, &b) == 2) { keyCombo(a, b); return; }
  if (line.startsWith("CC ")) { consumerKey((uint16_t)strtol(line.c_str() + 3, nullptr, 16)); return; }
  if (line.startsWith("W ")) {
    int t = line.indexOf('\t');
    wifiSsid = t > 0 ? line.substring(2, t) : line.substring(2); wifiPass = t > 0 ? line.substring(t + 1) : "";
    prefs.putString("ssid", wifiSsid); prefs.putString("pass", wifiPass);
    WiFi.disconnect(); wifiStart(); status("wifi_saved"); return;
  }
  if (line.startsWith("TG ")) {
    int t = line.indexOf('\t');
    if (t > 0) { tgToken = line.substring(3, t); tgChat = line.substring(t + 1); prefs.putString("tgt", tgToken); prefs.putString("tgc", tgChat); }
    status("tg_saved"); return;
  }
  if (line.startsWith("MUTE ")) { muteList = line.substring(5); prefs.putString("mute", muteList); return; }
  if (line == "TGTEST") { queueForward("✅ PhoneNotify 测试：ESP32 已能通过 Telegram 转发通知"); return; }
  if (line == "PING") {
    status(ancsReady ? "ancs_ready" : (connHandle != BLE_HS_CONN_HANDLE_NONE ? "connected" : "advertising"));
    Serial.printf("{\"t\":\"cfg\",\"wifi\":\"%s\",\"tg\":%s}\n", jesc(wifiSsid.c_str()).c_str(), tgToken.length() ? "true" : "false");
    return;
  }
  if (line == "UNPAIR") { NimBLEDevice::deleteAllBonds(); status("bonds_cleared"); return; }
}
static void handleSerial() {
  static String line;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n') { handleLine(line); line = ""; } else line += ch;
  }
}

void setup() {
  Serial.begin(115200);
  Keyboard.begin(); Consumer.begin();
  USB.productName("PhoneNotify Bridge");
  USB.manufacturerName("PhoneNotify");
  USB.begin();
  pinMode(BTN_PIN, INPUT_PULLUP);

  prefs.begin("pn", false);
  wifiSsid = prefs.getString("ssid", ""); wifiPass = prefs.getString("pass", "");
  tgToken = prefs.getString("tgt", ""); tgChat = prefs.getString("tgc", ""); muteList = prefs.getString("mute", "");

  nsQueue = xQueueCreate(64, sizeof(NsEvent));
  outQueue = xQueueCreate(32, sizeof(char*));
  fwdQueue = xQueueCreate(16, sizeof(char*));
  xTaskCreatePinnedToCore(fwdTask, "fwd", 12288, nullptr, 1, nullptr, 0);

  NimBLEDevice::init("MacNotify");
  NimBLEDevice::setPower(9);
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCB());
  server->advertiseOnDisconnect(true);
  NimBLEService* svc = server->createService("B7A6E5C4-1D2E-4F30-9A8B-0C1D2E3F4A5B");
  NimBLECharacteristic* pc = svc->createCharacteristic("B7A6E5C4-1D2E-4F30-9A8B-0C1D2E3F4A5C",
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::NOTIFY);
  pc->setValue("ok");
  svc->start();

  NimBLEAdvertisementData ad;
  ad.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  ad.setAppearance(0x00C0);
  uint8_t sol[18] = {17, 0x15};
  memcpy(sol + 2, ANCS_SVC.getValue(), 16);
  ad.addData(sol, sizeof(sol));
  NimBLEAdvertisementData sr; sr.setName("MacNotify");
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setAdvertisementData(ad);
  adv->setScanResponseData(sr);
  adv->start();
  wifiStart();
  status("advertising");
}

void loop() {
  handleSerial();
  pollButton();
  if (retrySecAt && millis() >= retrySecAt) {
    retrySecAt = 0;
    if (connHandle != BLE_HS_CONN_HANDLE_NONE && !ancsReady && !needSetup) { status("retry_pairing"); NimBLEDevice::startSecurity(connHandle); }
  }
  if (needSetup && connHandle != BLE_HS_CONN_HANDLE_NONE && millis() >= setupAt) {
    if (++setupTries > 30) { needSetup = false; status("ancs_gave_up"); } else trySetupANCS();
  }
  NsEvent e;
  while (xQueueReceive(nsQueue, &e, 0) == pdTRUE) {
    if (e.event == 2) { removeUnread(e.uid); Serial.printf("{\"t\":\"d\",\"uid\":%lu}\n", (unsigned long)e.uid); continue; }
    if (e.event != 0 || (e.flags & 0x04)) continue;
    uidOf[e.uid & 0xFF] = e.uid; catOf[e.uid & 0xFF] = e.cat;
    fetchQ.push_back(e);
  }
  char* p;
  while (xQueueReceive(outQueue, &p, 0) == pdTRUE) { Serial.println(p); free(p); }
  if (dsDirty) parseDS();
  if (inFlight && millis() - inFlightAt > 2000) inFlight = false;
  if (!inFlight && !fetchQ.empty() && ancsReady) {
    uint32_t uid = fetchQ.front().uid; fetchQ.erase(fetchQ.begin());
    requestAttrs(uid);
  }
  static uint32_t lastRssi = 0;
  if (ancsReady && cli && millis() - lastRssi > 1000) {
    lastRssi = millis();
    int r = cli->getRssi();
    if (r < 0) Serial.printf("{\"t\":\"r\",\"v\":%d}\n", r);
  }
  static uint32_t lastWifiChk = 0;
  if (millis() - lastWifiChk > 2000) { lastWifiChk = millis(); reportWifi(); }
  updateLed();
  delay(5);
}
