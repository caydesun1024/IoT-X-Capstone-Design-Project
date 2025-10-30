## 💊 스마트 약통 알람 시스템 (Smart Pill Dispenser Alarm System)

이 프로젝트는 **iOS 애플리케이션(SwiftUI)**, **Firebase Realtime Database (RTDB)**, **ESP8266 기반 하드웨어**를 연동하여 동작하는 스마트 약통 알람 시스템의 핵심 소프트웨어를 포함합니다. 사용자는 앱에서 알람을 설정/관리하며, 하드웨어는 설정된 시간에 LED를 깜빡여 복약 시간을 알립니다.

---

### 1. 시스템 아키텍처 (Architecture)

| 구성 요소 | 기술 스택 | 주요 역할 | 통신 흐름 |
| :--- | :--- | :--- | :--- |
| **클라이언트 (모바일 앱)** | SwiftUI (Swift), UserNotifications | 알람 설정/관리 (CRUD). 설정 변경 및 복약 확인 명령을 RTDB에 기록. | **REST API (PATCH, PUT, DELETE)** |
| **중앙 서버 (DB)** | Firebase Realtime Database | 알람 설정 (`/test/<id>`) 및 하드웨어 제어 명령 (`/test/<id>/turn_off`) 저장 및 동기화. | **JSON** 기반 데이터 교환 |
| **하드웨어 (약통)** | ESP8266 (C++), `Firebase_ESP_Client`, NTP | RTDB 상태 감시 및 설정 로드. NTP 시간을 기준으로 알람 트리거 및 **LED (74HC595)** 제어. | **RTDB Stream** 및 **Get/Set** |

---

### 2. 하드웨어 구현 (ESP8266/C++)

ESP8266 펌웨어는 Wi-Fi 연결, 시간 동기화, Firebase 통신, 그리고 시프트 레지스터(74HC595)를 통한 LED 제어를 담당합니다.

#### 2.1. 주요 기능

* **LED 제어:** 74HC595 시프트 레지스터를 사용하여 8개의 LED(D0~D7)를 제어합니다 (`DATA_PIN`: D5, `LATCH_PIN`: D6, `CLOCK_PIN`: D7). 알람 시 LED를 깜빡이며, 복약 확인 명령 시 LED를 끕니다.
* **시간 동기화:** **NTP Client**를 사용하여 KST(UTC+9) 기준으로 현재 시간과 요일을 동기화합니다.
* **알람 로직:**
    * **트리거:** 매분 00초에 현재 시간/요일과 RTDB에서 로드된 알람 목록(`alarms[]`)을 비교하여 일치하는 알람을 활성화합니다.
    * **설정 로드:** **20초 주기** 및 **알람 종료 직후**에 `/test` 경로에서 **Shallow Fetch**로 ID 목록을 가져온 후, 각 알람을 개별적으로 순차 로드하여 `alarms[]`를 업데이트합니다. (알람이 울리는 중에는 Fetch를 건너뛰어 안정성을 확보합니다.)
* **복약 확인 처리:**
    * **감시:** RTDB의 레거시 경로 스트림 (`/test`)을 통해 `/test/<id>/turn_off` 필드의 `true` 변화를 감지합니다.
    * **해제:** 앱으로부터 `true` 명령을 받으면 해당 알람의 LED를 끄고, RTDB의 `/turn_off` 필드를 다시 `false`로 원복(Reset)하여 다음 명령을 받을 수 있도록 합니다.

#### 2.2. 하드웨어 핀 설정

| 모듈 | 핀 정의 | ESP8266 (Wemos D1 mini) GPIO |
| :--- | :--- | :--- |
| **74HC595 (데이터)** | `DATA_PIN` | D5 (GPIO14) |
| **74HC595 (래치)** | `LATCH_PIN` | D6 (GPIO12) |
| **74HC595 (클럭)** | `CLOCK_PIN` | D7 (GPIO13) |

---

### 3. 모바일 앱 구현 (iOS/SwiftUI)

모바일 앱은 사용자 인터페이스, 알람 스케줄링 및 Firebase 연동을 담당합니다.

#### 3.1. 알람 데이터 모델 (`Alarm` Struct)

| 필드 | 타입 | 설명 |
| :--- | :--- | :--- |
| `id` | `String` | Firebase RTDB 키 (UUID). |
| `name` | `String` | 알람 이름. |
| `time` | `String` | 알람 시간 ("HH:mm"). |
| `repeatDays` | `[Int]` | 반복 요일 (1=월, 7=일). |
| `leds` | `[Int]` | 사용할 LED 번호 목록 (1..8). |
| `enabled` | `Bool` | 알람 활성화 여부. |

#### 3.2. 핵심 기능

* **CRUD 관리:** `Store` 클래스 및 `API` 클라이언트를 통해 RTDB에 저장된 알람 목록을 **Fetch**하고, 새로운 알람을 **Save** (PUT), 기존 알람을 **Delete**하며, 활성화 여부를 **Patch**합니다.
* **로컬 알림 스케줄링 (`Noti`):**
    * `UNUserNotificationCenter`를 사용하여 알람의 **반복 요일** 및 **시간**에 맞춰 **로컬 알림**을 예약합니다.
    * 알림 카테고리 (`MEDICATION_ALARM`)에 "**복약 확인**" 및 "**5분 후 다시**" 액션 버튼을 추가합니다.
* **복약 확인 명령:**
    * 앱에서 "복약 확인" 버튼을 누르면, `API.confirmMedication` 함수를 호출하여 RTDB의 `/test/<alarmId>` 경로에 `{"turn_off": true}`를 **PATCH**하여 하드웨어에 알람 해제 명령을 전달합니다.
* **사용자 인터페이스:**
    * `AlarmListView`: 알람 목록을 표시하고 검색/필터링, 스와이프 액션(삭제, 복제) 및 편집 기능을 제공합니다.
    * `AddAlarmView`/`EditAlarmView`: 시간, 요일, LED 선택을 위한 UI를 제공합니다. (`DaysPicker`, `LEDMultiPicker`)
    * `MedicationConfirmationView`: 복약 확인 모달 창을 표시하며, 확인 또는 스누즈 기능을 제공합니다.
