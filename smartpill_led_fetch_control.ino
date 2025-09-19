#include <ESP8266WiFi.h>
#include <WiFiManager.h>
#include <Firebase_ESP_Client.h>
#include <NTPClient.h>
#include <WiFiUdp.h>

#include "addons/TokenHelper.h"
#include "addons/RTDBHelper.h"

// ===== Firebase 설정 =====
#define API_KEY "AIzaSyCqbU_-lhuYNmjGOSlVJs6d4CQqr2_prn8"
#define DATABASE_URL "https://smartpill-1a1e1-default-rtdb.asia-southeast1.firebasedatabase.app/"

// 기존(레거시) 경로만 사용: /test/<id>/turn_off
#define STREAM_PATH_OLD "/test"

FirebaseData fbdo;             // 일반 RTDB
FirebaseData streamOldFb;      // 레거시 경로 스트림
FirebaseAuth auth;
FirebaseConfig config;

bool signupOK = false;

// ===== NTP (KST = UTC+9) =====
WiFiUDP ntpUDP;
NTPClient timeClient(ntpUDP, "pool.ntp.org", 9 * 3600);

// ===== 74HC595 (Wemos D1 mini) =====
#define DATA_PIN   D5 // GPIO14
#define LATCH_PIN  D6 // GPIO12
#define CLOCK_PIN  D7 // GPIO13

uint8_t ledStates = 0;
bool    ledActive[8] = {false};   // 깜빡임 대상
uint8_t ledRefCnt[8] = {0};       // LED 공유 시 참조 카운트

// 깜빡임
#define BLINK_INTERVAL 500
unsigned long blinkPrev = 0;

// ===== 알람 스키마 =====
struct AlarmEx {
  String   id;        // /test/<id>의 <id> (키 이름)
  String   timeHM;    // "HH:MM"
  uint8_t  daysMask;  // bit0=일..bit6=토 (NTPClient 0=일)
  uint8_t  ledsMask;  // bit0=LED0..bit7=LED7
  bool     enabled;
};
#define MAX_ALARMS 20
AlarmEx  alarms[MAX_ALARMS];
int      alarmCount = 0;
bool     alarmRinging[MAX_ALARMS] = {false};

// ===== 시리얼 로그 타이머 =====
unsigned long timePrevMillis = 0;

// ===== 콜백→루프 비동기 처리 =====
volatile bool pendingDismiss = false;
String         pendingDismissId = "";

// 스트림 디바운스
unsigned long streamCooldownUntilOld = 0;

// ===== 토글 =====
#define ENABLE_STREAM_OLD 1   // ✅ 기존 경로만 듣기
#define ENABLE_FETCH      1   // 20초에 shallow fetch

// (옵션) 알 수 없는 ID면 모두 끄기 (디버깅/안전망)
#define FALLBACK_DISMISS_ALL_IF_UNKNOWN_ID 0

// ===== 점진적(initial) 페치 =====
String pendingIds[MAX_ALARMS];
int    pendingCount = 0;
int    pendingIndex = 0;
const unsigned long FETCH_BUDGET_MS = 12; // 루프 길게 못 잡게

// ===== 00초/20초 래치 =====
bool sec0Latch  = false;  // 00초 트리거 1회용
bool sec20Latch = false;  // 20초 fetch 1회용

// ===== 유틸 =====
void updateLEDs(uint8_t states) {
  digitalWrite(LATCH_PIN, LOW);
  shiftOut(DATA_PIN, CLOCK_PIN, MSBFIRST, states);
  digitalWrite(LATCH_PIN, HIGH);
}

// ===== 표시용 헬퍼 =====
const char* DAY_KR[7] = {"일","월","화","수","목","금","토"};

String daysMaskToStr(uint8_t mask) {
  String s = "";
  for (int i = 0; i < 7; i++) {
    if (mask & (1 << i)) {
      if (s.length()) s += ",";
      s += DAY_KR[i];
    }
  }
  return s.length() ? s : "-";
}

String ledsMaskToStr(uint8_t mask) {
  String s = "";
  for (int i = 0; i < 8; i++) {
    if (mask & (1 << i)) {
      if (s.length()) s += ",";
      s += String(i + 1); // LED 라벨(1..8)
    }
  }
  return s.length() ? s : "-";
}

void printAlarmList(const char* tag) {
  Serial.printf("[ALARM_LIST] %s count=%d\n", tag, alarmCount);
  for (int i = 0; i < alarmCount; i++) {
    Serial.printf("  #%02d id=%s time=%s days={%s} leds=[%s] enabled=%s ringing=%s\n",
                  i,
                  alarms[i].id.c_str(),
                  alarms[i].timeHM.c_str(),
                  daysMaskToStr(alarms[i].daysMask).c_str(),
                  ledsMaskToStr(alarms[i].ledsMask).c_str(),
                  alarms[i].enabled ? "true" : "false",
                  alarmRinging[i] ? "true" : "false");
  }
}

inline uint8_t modelDayToBit(int d) {   // 1=월..7=일 -> 0=일..6=토
  return (d == 7) ? 0 : d;
}

inline void addLedToMask(uint8_t &mask, int ledLabel) { // 1..8 -> 0..7 bit mask
  int idx = ledLabel - 1;
  if (idx >= 0 && idx < 8) mask |= (1 << idx);
}

// ===== LED 제어 =====
void activateAlarm(const AlarmEx &a) {
  for (int led = 0; led < 8; led++) {
    if (a.ledsMask & (1 << led)) {
      if (ledRefCnt[led] == 0) ledActive[led] = true;
      ledRefCnt[led]++;
    }
  }
}

// ===== 알람/페치 상태 관리 (추가) =====
bool fetchPendingAfterAlarm = false;

bool isAnyAlarmActive() {
  for (int i = 0; i < alarmCount; i++) {
    if (alarmRinging[i]) return true;
  }
  return false;
}

void dismissAlarmById(const String &id) {
  int idx = -1;
  for (int i = 0; i < alarmCount; i++) {
    if (alarms[i].id == id) { idx = i; break; }
  }

  if (idx < 0) {
    Serial.printf("[WARN] dismiss id not found: '%s'\n", id.c_str());
    #if FALLBACK_DISMISS_ALL_IF_UNKNOWN_ID
      Serial.println("[WARN] fallback: dismiss ALL ringing alarms");
      bool anyDismissed = false;
      for (int j = 0; j < alarmCount; j++) {
        if (!alarmRinging[j]) continue;
        const AlarmEx &a2 = alarms[j];
        alarmRinging[j] = false;
        anyDismissed = true;
        for (int led = 0; led < 8; led++) {
          if (a2.ledsMask & (1 << led)) {
            if (ledRefCnt[led] > 0) {
              ledRefCnt[led]--;
              if (ledRefCnt[led] == 0) {
                ledActive[led] = false;
                ledStates &= ~(1 << led);
              }
            }
          }
        }
      }
      if (anyDismissed) {
        updateLEDs(ledStates);
        fetchPendingAfterAlarm = true; // 전체 종료 후 즉시 fetch 예약
      }
    #endif
    return;
  }

  if (!alarmRinging[idx]) {
    Serial.printf("[INFO] dismiss but not ringing: id=%s\n", id.c_str());
    return;
  }

  alarmRinging[idx] = false;
  const AlarmEx &a = alarms[idx];

  for (int led = 0; led < 8; led++) {
    if (a.ledsMask & (1 << led)) {
      if (ledRefCnt[led] > 0) {
        ledRefCnt[led]--;
        if (ledRefCnt[led] == 0) {
          ledActive[led] = false;
          ledStates &= ~(1 << led);  // 완전 OFF
        }
      }
    }
  }
  updateLEDs(ledStates);
  Serial.printf("[DISMISS] id=%s\n", id.c_str());

  // 알람이 끝나면 fetch 예약 (추가)
  fetchPendingAfterAlarm = true;
}

// ===== 스트림 콜백(레거시 경로) =====
// ===== 스트림 콜백(레거시 경로) =====
void streamOldCallback(FirebaseStream data) {
  if (millis() < streamCooldownUntilOld) return;  // 디바운스
  if (String(data.streamPath()) != STREAM_PATH_OLD) return;

  String dpath = data.dataPath();  // 예: "/A1/turn_off" 또는 "/A1"

  // 1) 기존: /<id>/turn_off 이벤트 처리
  if (dpath.endsWith("/turn_off")) {
    int p1 = dpath.indexOf('/', 1);
    if (p1 < 0) return;
    String id = dpath.substring(1, p1); // "<id>"

    if (data.dataTypeEnum() == fb_esp_rtdb_data_type_boolean && data.boolData()) {
      Serial.printf("[STREAM-OLD] turn_off TRUE id=%s\n", id.c_str());
      pendingDismissId = id;
      pendingDismiss   = true;
      streamCooldownUntilOld = millis() + 150;
    }
    return;
  }

  // 2) 새로 추가: /<id> 전체 JSON PATCH 이벤트 처리
  if (data.dataTypeEnum() == fb_esp_rtdb_data_type_json) {
    // dpath == "/A1" 같은 경우
    String id = dpath.substring(1); // "A1"
    FirebaseJson* json = data.to<FirebaseJson*>();
    FirebaseJsonData jd;
    json->get(jd, "turn_off"); // turn_off 필드 추출
    if (jd.success && jd.typeNum == FirebaseJson::JSON_BOOL && jd.boolValue) {
      Serial.printf("[STREAM-OLD] turn_off TRUE (JSON PATCH) id=%s\n", id.c_str());
      pendingDismissId = id;
      pendingDismiss   = true;
      streamCooldownUntilOld = millis() + 150;
    }
  }
}

void streamOldTimeout(bool timeout) {
  if (timeout) { Serial.println("RTDB stream OLD timeout, reconnecting..."); }
}

// ===== 얕은 조회로 키 목록만 수집 =====
bool collectAlarmIdsShallow() {
  pendingCount = 0;
  pendingIndex = 0;

  if (!Firebase.RTDB.getShallowData(&fbdo, "/test")) {
    Serial.printf("[FETCH_KEYS] shallow FAIL: %s\n", fbdo.errorReason().c_str());
    return false;
  }
  yield();

  FirebaseJson *json = fbdo.to<FirebaseJson *>();
  size_t len = json->iteratorBegin();
  String key, value; int type;

  for (size_t i = 0; i < len && pendingCount < MAX_ALARMS; i++) {
    json->iteratorGet(i, type, key, value);
    if (key.length() > 0) {
      pendingIds[pendingCount++] = key;  // 하위 키만 저장
    }
    yield();
  }
  json->iteratorEnd();

  Serial.printf("[FETCH_KEYS] found %d ids\n", pendingCount);
  return true;
}

// ===== 키 하나를 세부 필드로 로드 → alarms[]에 push =====
bool fetchOneAlarmById(const String &id) {
  String base = "/test/" + id;

  String  timeHM = "07:00";
  bool    enabled = true;
  uint8_t daysMask = 0, ledsMask = 0;

  // time (필수)
  if (Firebase.RTDB.getString(&fbdo, base + "/time")) {
    timeHM = fbdo.stringData();
  } else {
    return true; // 필수 누락: 스킵
  }
  yield();

  // enabled
  if (Firebase.RTDB.getBool(&fbdo, base + "/enabled")) {
    enabled = fbdo.boolData();
  }
  yield();

  // repeatDays
  if (Firebase.RTDB.getArray(&fbdo, base + "/repeatDays")) {
    FirebaseJsonArray *arr = fbdo.to<FirebaseJsonArray *>();
    for (size_t j = 0; j < arr->size(); j++) {
      FirebaseJsonData jd; arr->get(jd, j);
      if (jd.success && jd.typeNum == FirebaseJson::JSON_INT) {
        int d = jd.intValue; // 권장 1..7
        uint8_t bit = modelDayToBit(d);
        if (bit <= 6) daysMask |= (1 << bit);
      }
      yield();
    }
  }
  yield();

  // leds
  if (Firebase.RTDB.getArray(&fbdo, base + "/leds")) {
    FirebaseJsonArray *arr = fbdo.to<FirebaseJsonArray *>();
    for (size_t j = 0; j < arr->size(); j++) {
      FirebaseJsonData jd; arr->get(jd, j);
      if (jd.success && jd.typeNum == FirebaseJson::JSON_INT) {
        addLedToMask(ledsMask, jd.intValue);
      }
      yield();
    }
  }
  yield();

  if (daysMask == 0 || ledsMask == 0) return true;

  if (alarmCount < MAX_ALARMS) {
    alarms[alarmCount] = { id, timeHM, daysMask, ledsMask, enabled };
    alarmRinging[alarmCount] = false;
    alarmCount++;
  }
  return true;
}

// ===== 주기 페치 — shallow → 조각 처리 =====
void periodicFetchSafe() {
  if (!collectAlarmIdsShallow()) return;

  alarmCount = 0;
  for (int i = 0; i < pendingCount && alarmCount < MAX_ALARMS; i++) {
    unsigned long t0 = millis();
    fetchOneAlarmById(pendingIds[i]);
    if (millis() - t0 > FETCH_BUDGET_MS) yield();
  }
  Serial.printf("[RUN_FETCH] loaded alarms: %d\n", alarmCount);
  printAlarmList("AFTER_FETCH");   // 👈 fetch 직후 목록 보여주기
}

// ===== SETUP / LOOP =====
void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  delay(200);

  pinMode(DATA_PIN, OUTPUT);
  pinMode(CLOCK_PIN, OUTPUT);
  pinMode(LATCH_PIN, OUTPUT);
  ledStates = 0; updateLEDs(0x00);

  // WiFi
  WiFiManager wm;
  wm.setConfigPortalTimeout(0);
  Serial.println("[BOOT] WiFiManager start");
  if (!wm.autoConnect("smartpill")) ESP.restart();
  Serial.print("[BOOT] WiFi OK, IP="); Serial.println(WiFi.localIP());
  WiFi.setSleep(false);

  // NTP
  Serial.println("[BOOT] NTP begin");
  timeClient.begin();
  timeClient.update();

  // Firebase CONFIG (RAM/WDT-safe)
  fbdo.setBSSLBufferSize(4096, 512);
  fbdo.setResponseSize(1024);
  streamOldFb.setBSSLBufferSize(4096, 256);
  streamOldFb.setResponseSize(768);

  config.api_key = API_KEY;
  config.database_url = DATABASE_URL;
  config.timeout.socketConnection = 5000;
  config.timeout.serverResponse   = 5000;

  // Firebase
  Serial.println("[BOOT] Firebase signUp...");
  if (Firebase.signUp(&config, &auth, "", "")) {
    signupOK = true;
    Serial.println("[BOOT] signUp OK");
  } else {
    Serial.printf("[BOOT] signUp FAIL: %s\n", fbdo.errorReason().c_str());
  }
  config.token_status_callback = tokenStatusCallback;

  Serial.println("[BOOT] Firebase begin");
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);

  // 스트림 시작 — ✅ 기존 경로만
  #if ENABLE_STREAM_OLD
    Serial.println("[BOOT] Stream OLD begin " STREAM_PATH_OLD);
    if (!Firebase.RTDB.beginStream(&streamOldFb, STREAM_PATH_OLD)) {
      Serial.printf("[BOOT] stream OLD FAIL: %s\n", streamOldFb.errorReason().c_str());
    } else {
      Firebase.RTDB.setStreamCallback(&streamOldFb, streamOldCallback, streamOldTimeout);
      Serial.println("[BOOT] stream OLD OK");
    }
  #endif

  // 초기 shallow fetch
  #if ENABLE_FETCH
    Serial.println("[BOOT] initial shallow fetch");
    periodicFetchSafe();
    printAlarmList("BOOT_INITIAL");   // 👈 부팅 직후 초기 목록
  #endif
}

void loop() {
  yield(); // 항상 WDT 먹이기

  // (A) turn_off 처리 — 콜백이 아닌 여기서 네트워크 호출
  if (pendingDismiss) {
    pendingDismiss = false;
    Serial.printf("[DISMISS_REQ] id=%s\n", pendingDismissId.c_str());

    dismissAlarmById(pendingDismissId);

    if (Firebase.ready()) {
      // 기존 경로만 false로 원복
      Firebase.RTDB.setBool(&fbdo, "/test/" + pendingDismissId + "/turn_off", false);
    }
    yield();
  }

  // (B) 정상 동작
  timeClient.update();

  String nowStr    = timeClient.getFormattedTime(); // "HH:MM:SS"
  int    sec       = timeClient.getSeconds();
  int    currentDay= timeClient.getDay();           // 0=일..6=토

  // 1초 로그
  if (millis() - timePrevMillis > 1000) {
    timePrevMillis = millis();
    Serial.printf("%d %s\n", currentDay, nowStr.c_str());
  }

  // 00초: 'HH:MM' 비교로 트리거 (엣지 래치로 중복 방지)
  if (sec == 0) {
    if (!sec0Latch) {
      sec0Latch = true;

      String currentHM = nowStr.substring(0, 5); // "HH:MM"
      for (int i = 0; i < alarmCount; i++) {
        AlarmEx &a = alarms[i];
        if (!a.enabled) continue;

        bool dayMatch  = (a.daysMask & (1 << currentDay));
        bool timeMatch = (a.timeHM == currentHM);

        if (dayMatch && timeMatch) {
          if (!alarmRinging[i]) {
            alarmRinging[i] = true;
            Serial.printf("[ALARM] %s LEDs(0x%02X) id=%s\n",
                          a.timeHM.c_str(), a.ledsMask, a.id.c_str());
            activateAlarm(a);
          } else {
            Serial.printf("[SKIP] already ringing id=%s\n", a.id.c_str());
          }
        }
      }
      yield();
    }
  } else if (sec0Latch) {
    sec0Latch = false; // 다음 00초를 위해 해제
  }

  // 20초: 주기 shallow fetch (엣지 래치로 1회만)
  if (sec == 20) {
    if (!sec20Latch) {
      sec20Latch = true;
      #if ENABLE_FETCH
        if (signupOK && Firebase.ready() && !isAnyAlarmActive()) {
          Serial.println("[RUN] 20s shallow+step fetch");
          periodicFetchSafe();
        } else if (isAnyAlarmActive()) {
          Serial.println("[SKIP] fetch blocked: alarm active");
        }
      #endif
      yield();
    }
  } else if (sec20Latch) {
    sec20Latch = false;
  }

  // LED 깜빡임 (확인 전까지 무한)
  if (millis() - blinkPrev >= BLINK_INTERVAL) {
    blinkPrev = millis();
    for (int i = 0; i < 8; i++) {
      if (ledActive[i]) {
        if (ledStates & (1 << i)) ledStates &= ~(1 << i);
        else                      ledStates |=  (1 << i);
      } else {
        ledStates &= ~(1 << i);
      }
    }
    updateLEDs(ledStates);
  }

  // 알람 종료 직후 fetch 실행 (추가)
  if (fetchPendingAfterAlarm && !isAnyAlarmActive()) {
    fetchPendingAfterAlarm = false;
    if (signupOK && Firebase.ready()) {
      Serial.println("[RUN] fetch immediately after alarm dismissed");
      periodicFetchSafe();
    }
  }

  // 루프 말미
  yield();
}
