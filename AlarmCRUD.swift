import SwiftUI
import UserNotifications

// ====== CONFIG ======
fileprivate let baseURL = "https://smartpill-1a1e1-default-rtdb.asia-southeast1.firebasedatabase.app/"
fileprivate let rootPath = "/test"
fileprivate let authQuery = ""         // 필요 시 "?auth=ID_TOKEN"

// ====== MODEL ======
struct Alarm: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var time: String           // "HH:mm"
    var repeatDays: [Int]      // 1=월 ... 7=일
    var leds: [Int]            // 여러 개 LED 선택 가능
    var enabled: Bool = true
}

// ====== REST CLIENT ======
enum API {
    static func url(_ path: String) -> URL { URL(string: "\(baseURL)\(path).json\(authQuery)")! }
    
    static func fetchAll() async throws -> [Alarm] {
        let (data, _) = try await URLSession.shared.data(from: url(rootPath))
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [Alarm] = []
            for (key, v) in dict {
                guard let m = v as? [String: Any] else { continue }
                let name = m["name"] as? String ?? "알람"
                let time = m["time"] as? String ?? "07:00"
                let days = m["repeatDays"] as? [Int] ?? []
                let leds = m["leds"] as? [Int] ?? []
                let enabled = m["enabled"] as? Bool ?? true
                out.append(Alarm(id: key, name: name, time: time, repeatDays: days, leds: leds, enabled: enabled))
            }
            return out.sorted { $0.time < $1.time }
        }
        return []
    }
    
    static func save(_ alarm: Alarm) async throws {
        var req = URLRequest(url: url("\(rootPath)/\(alarm.id)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(alarm)
        _ = try await URLSession.shared.data(for: req)
    }
    
    static func patchEnabled(id: String, enabled: Bool) async throws {
        var req = URLRequest(url: url("\(rootPath)/\(id)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        _ = try await URLSession.shared.data(for: req)
    }
    
    static func delete(id: String) async throws {
        var req = URLRequest(url: url("\(rootPath)/\(id)"))
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }
    
    // 앱에서 "복약 확인" 시 보드에 끄기 신호 전송: /test/<id>/turn_off = true
    static func confirmMedication(alarmId: String, leds _: [Int]) async throws {
        var req = URLRequest(url: url("\(rootPath)/\(alarmId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["turn_off": true]) // Bool true!
        _ = try await URLSession.shared.data(for: req)
    }
}

// ====== NOTIFICATION (로컬) ======
final class Noti {
    static let shared = Noti(); private init() {}
    
    func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound,.badge]) { granted, error in
            print("알림 권한 요청 결과: \(granted), 오류: \(error?.localizedDescription ?? "없음")")
        }
    }
    func schedule(for alarm: Alarm) {
        print("알람 스케줄링 시작: \(alarm.name), 활성화: \(alarm.enabled)")
        guard alarm.enabled else { 
            print("알람이 비활성화되어 있음")
            return 
        }
        cancel(for: alarm)
        guard let (h,m) = parseHHmm(alarm.time) else { 
            print("시간 파싱 실패: \(alarm.time)")
            return 
        }
        let ledsLabel = alarm.leds.sorted().map(String.init).joined(separator: ",")
        print("알람 시간: \(h):\(m), 요일: \(alarm.repeatDays), LED: \(ledsLabel)")
        
        for d in alarm.repeatDays {
            var comp = DateComponents()
            comp.hour = h; comp.minute = m
            comp.weekday = (d == 7 ? 1 : d + 1)
            let content = UNMutableNotificationContent()
            content.title = alarm.name.isEmpty ? "알람" : alarm.name
            content.body  = "\(alarm.time) • LED \(ledsLabel)"
            content.sound = .default
            content.categoryIdentifier = "MEDICATION_ALARM"
            content.userInfo = [
                "alarmId": alarm.id,
                "leds": alarm.leds,
                "alarmName": alarm.name
            ]
            let trig = UNCalendarNotificationTrigger(dateMatching: comp, repeats: true)
            let req = UNNotificationRequest(identifier: "\(alarm.id)_\(d)", content: content, trigger: trig)
            
            UNUserNotificationCenter.current().add(req) { error in
                if let error = error {
                    print("알림 추가 실패: \(error.localizedDescription)")
                } else {
                    print("알림 추가 성공: \(alarm.name) - 요일 \(d)")
                }
            }
        }
    }
    func cancel(for alarm: Alarm) {
        let ids = (1...7).map{"\(alarm.id)_\($0)"}
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
    func setupNotificationCategories() {
        let confirmAction = UNNotificationAction(
            identifier: "CONFIRM_MEDICATION",
            title: "복약 확인",
            options: [.foreground]
        )
        let snoozeAction = UNNotificationAction(
            identifier: "SNOOZE_MEDICATION",
            title: "5분 후 다시",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "MEDICATION_ALARM",
            actions: [confirmAction, snoozeAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        print("알림 카테고리 설정 완료")
    }
    
    // 테스트용 즉시 알림
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "테스트 알림"
        content.body = "알림이 제대로 작동하는지 테스트합니다"
        content.sound = .default
        content.categoryIdentifier = "MEDICATION_ALARM"
        content.userInfo = [
            "alarmId": "test",
            "leds": [1, 2],
            "alarmName": "테스트 알람"
        ]
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(identifier: "test_notification", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("테스트 알림 추가 실패: \(error.localizedDescription)")
            } else {
                print("테스트 알림 추가 성공 - 3초 후 표시됩니다")
            }
        }
    }
    private func parseHHmm(_ s: String)->(Int,Int)? {
        let p = s.split(separator: ":"); guard p.count==2, let h=Int(p[0]), let m=Int(p[1]) else {return nil}
        return (h,m)
    }
}

// ====== APP STATE ======
@MainActor
final class Store: ObservableObject {
    @Published var alarms: [Alarm] = []
    @Published var query = ""
    @Published var showEnabledOnly = false
    @Published var isRefreshing = false
    @Published var showingMedicationConfirmation = false
    @Published var currentAlarm: Alarm?
    
    var filtered: [Alarm] {
        alarms.filter { a in
            (query.isEmpty || a.name.localizedCaseInsensitiveContains(query)) &&
            (!showEnabledOnly || a.enabled)
        }
    }
    
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do { alarms = try await API.fetchAll() }
        catch { print("fetch error:", error) }
    }
    
    func save(_ alarm: Alarm) async {
        do {
            try await API.save(alarm)
            if alarm.enabled { Noti.shared.schedule(for: alarm) } else { Noti.shared.cancel(for: alarm) }
            await refresh()
        } catch { print("save error:", error) }
    }
    
    func delete(_ id: String) async {
        do { try await API.delete(id: id); await refresh() }
        catch { print("delete error:", error) }
    }
    
    func setEnabled(_ id: String, _ enabled: Bool) async {
        do {
            try await API.patchEnabled(id: id, enabled: enabled)
            if let a = alarms.first(where: {$0.id==id}) {
                var x = a; x.enabled = enabled
                if enabled { Noti.shared.schedule(for: x) } else { Noti.shared.cancel(for: x) }
            }
            await refresh()
        } catch { print("enable error:", error) }
    }
    
    func confirmMedication(alarmId: String, leds: [Int]) async {
        do {
            try await API.confirmMedication(alarmId: alarmId, leds: leds)
            print("복약 확인 완료: 알람 ID \(alarmId), LED \(leds)")
        } catch { 
            print("복약 확인 오류:", error) 
        }
    }
    
    func showMedicationConfirmation(for alarm: Alarm) {
        currentAlarm = alarm
        showingMedicationConfirmation = true
    }
    
    func hideMedicationConfirmation() {
        showingMedicationConfirmation = false
        currentAlarm = nil
    }
}

// ====== REUSABLE PICKERS ======
struct DaysPicker: View {
    @Binding var selection: Set<Int>
    private let days = [(1,"월"),(2,"화"),(3,"수"),(4,"목"),(5,"금"),(6,"토"),(7,"일")]
    var body: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 8), count: 7), spacing: 8) {
            ForEach(days, id:\.0) { (value, label) in
                Button {
                    if selection.contains(value) { selection.remove(value) }
                    else { selection.insert(value) }
                } label: {
                    Text(label)
                        .frame(maxWidth:.infinity, minHeight: 40)
                        .background(selection.contains(value) ? Color.blue : Color.gray.opacity(0.2))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct LEDMultiPicker: View {
    @Binding var selections: Set<Int>
    private let leds = Array(1...8)
    var body: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 8), count: 8), spacing: 8) {
            ForEach(leds, id:\.self) { n in
                Button {
                    if selections.contains(n) { selections.remove(n) }
                    else { selections.insert(n) }
                } label: {
                    Text("\(n)")
                        .frame(maxWidth:.infinity, minHeight: 36)
                        .background(selections.contains(n) ? Color.orange : Color.gray.opacity(0.2))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RepeatPresetBar: View {
    @Binding var days: Set<Int>
    private let everyDay: Set<Int> = Set(1...7)
    private let weekdays: Set<Int> = Set(1...5)
    private let weekend: Set<Int>  = Set([6,7])
    
    var body: some View {
        HStack {
            Button("매일") {
                if days == everyDay { days.removeAll() } else { days = everyDay }
            }.buttonStyle(.bordered).tint(days == everyDay ? .blue : .gray)
            
            Button("주중") {
                if days == weekdays { days.removeAll() } else { days = weekdays }
            }.buttonStyle(.bordered).tint(days == weekdays ? .blue : .gray)
            
            Button("주말") {
                if days == weekend { days.removeAll() } else { days = weekend }
            }.buttonStyle(.bordered).tint(days == weekend ? .blue : .gray)
        }
    }
}

// ====== ADD / EDIT ======
struct AddAlarmView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: Store
    @State private var name = ""
    @State private var time = Date()
    @State private var days: Set<Int> = []
    @State private var leds: Set<Int> = []
    
    @State private var showDayWarning = false
    @State private var showLedWarning = false
    
    var body: some View {
        Form {
            Section(header: Text("알람 이름")) {
                TextField("알람 이름", text: $name)
            }
            Section(header: Text("시간")) {
                DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute)
            }
            Section(header: Text("요일 반복")) {
                RepeatPresetBar(days: $days)
                DaysPicker(selection: $days)
                if showDayWarning && days.isEmpty {
                    Text("요일을 하나 이상 선택하세요.").foregroundColor(.red).font(.caption)
                }
            }
            Section(header: Text("LED 선택")) {
                LEDMultiPicker(selections: $leds)
                if showLedWarning && leds.isEmpty {
                    Text("LED를 하나 이상 선택하세요.").foregroundColor(.red).font(.caption)
                }
            }
            Button {
                if days.isEmpty { showDayWarning = true } else { showDayWarning = false }
                if leds.isEmpty { showLedWarning = true } else { showLedWarning = false }
                guard !days.isEmpty, !leds.isEmpty else { return }
                
                Task {
                    let f = DateFormatter(); f.dateFormat = "HH:mm"
                    let a = Alarm(name: name.isEmpty ? "새 알람" : name,
                                  time: f.string(from: time),
                                  repeatDays: Array(days).sorted(),
                                  leds: Array(leds).sorted(),
                                  enabled: true)
                    await store.save(a)
                    dismiss()
                }
            } label: {
                Text("저장").frame(maxWidth:.infinity).padding()
                    .background(Color.green).foregroundColor(.white).cornerRadius(10)
            }
        }
        .navigationTitle("알람 추가")
    }
}

struct EditAlarmView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: Store
    @State var alarm: Alarm
    @State private var name = ""
    @State private var time = Date()
    @State private var days: Set<Int> = []
    @State private var leds: Set<Int> = []
    
    @State private var showDayWarning = false
    @State private var showLedWarning = false
    
    var body: some View {
        Form {
            Section(header: Text("알람 이름")) {
                TextField("알람 이름", text: $name)
            }
            Section(header: Text("시간")) {
                DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute)
            }
            Section(header: Text("요일 반복")) {
                RepeatPresetBar(days: $days)
                DaysPicker(selection: $days)
                if showDayWarning && days.isEmpty {
                    Text("요일을 하나 이상 선택하세요.").foregroundColor(.red).font(.caption)
                }
            }
            Section(header: Text("LED 선택")) {
                LEDMultiPicker(selections: $leds)
                if showLedWarning && leds.isEmpty {
                    Text("LED를 하나 이상 선택하세요.").foregroundColor(.red).font(.caption)
                }
            }
            Section {
                Toggle("알람 활성화", isOn: Binding(
                    get: { alarm.enabled },
                    set: { newVal in
                        alarm.enabled = newVal
                        Task { await store.setEnabled(alarm.id, newVal) }
                    }
                ))
            }
            Button {
                if days.isEmpty { showDayWarning = true } else { showDayWarning = false }
                if leds.isEmpty { showLedWarning = true } else { showLedWarning = false }
                guard !days.isEmpty, !leds.isEmpty else { return }
                
                Task {
                    let f = DateFormatter(); f.dateFormat = "HH:mm"
                    var u = alarm
                    u.name = name.isEmpty ? "알람" : name
                    u.time = f.string(from: time)
                    u.repeatDays = Array(days).sorted()
                    u.leds = Array(leds).sorted()
                    await store.save(u)
                    dismiss()
                }
            } label: {
                Text("수정 저장").frame(maxWidth:.infinity).padding()
                    .background(Color.blue).foregroundColor(.white).cornerRadius(10)
            }
        }
        .navigationTitle("알람 편집")
        .onAppear {
            name = alarm.name
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            if let d = f.date(from: alarm.time) { time = d }
            days = Set(alarm.repeatDays)
            leds = Set(alarm.leds)
        }
    }
}

// ====== LIST ======
struct AlarmListView: View {
    @EnvironmentObject var store: Store
    @State private var showAdd = false
    @State private var editing: Alarm?
    
    var body: some View {
        List {
            if !store.alarms.isEmpty {
                Section { Toggle("켜짐만 보기", isOn: $store.showEnabledOnly) }
            }
            ForEach(store.filtered) { a in
                HStack {
                    VStack(alignment: .leading) {
                        Text(a.name).font(.headline)
                        Text("\(a.time) • \(daysLabel(a.repeatDays)) • LED \(ledsLabel(a.leds))")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { a.enabled },
                        set: { newVal in Task { await store.setEnabled(a.id, newVal) } }
                    )).labelsHidden()
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = a }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { Task { await store.delete(a.id) } } label: {
                        Label("삭제", systemImage: "trash")
                    }
                    Button { // 복제
                        Task {
                            var copy = a; copy.id = UUID().uuidString
                            copy.name = a.name + " 복제"
                            await store.save(copy)
                        }
                    } label: {
                        Label("복제", systemImage: "doc.on.doc")
                    }.tint(.orange)
                }
            }
        }
        .navigationTitle("알람 목록")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { Noti.shared.sendTestNotification() } label: {
                    Text("테스트")
                }
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }.disabled(store.isRefreshing)
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .searchable(text: $store.query, prompt: "알람 이름 검색")
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showAdd) { NavigationView { AddAlarmView().environmentObject(store) } }
        .sheet(item: $editing) { a in NavigationView { EditAlarmView(alarm: a).environmentObject(store) } }
        .sheet(isPresented: $store.showingMedicationConfirmation) {
            if let alarm = store.currentAlarm {
                MedicationConfirmationView(alarm: alarm)
                    .environmentObject(store)
            }
        }
        .onAppear {
            Noti.shared.requestAuth()
            Noti.shared.setupNotificationCategories()
            Task { await store.refresh() }
        }
    }
    
    private func daysLabel(_ days: [Int]) -> String {
        let m = [1:"월",2:"화",3:"수",4:"목",5:"금",6:"토",7:"일"]
        let labels = days.sorted().compactMap { m[$0] }
        return labels.isEmpty ? "요일 없음" : labels.joined(separator: ",")
    }
    
    private func ledsLabel(_ leds: [Int]) -> String {
        let s = leds.sorted().map(String.init).joined(separator: ",")
        return s.isEmpty ? "-" : s
    }
}

// ====== MEDICATION CONFIRMATION MODAL ======
struct MedicationConfirmationView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: Store
    let alarm: Alarm
    @State private var isConfirming = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // 헤더
                VStack(spacing: 10) {
                    Image(systemName: "pills.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("💊 복약 시간")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text(alarm.name.isEmpty ? "알람" : alarm.name)
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    Text("LED \(alarm.leds.sorted().map(String.init).joined(separator: ", "))")
                        .font(.headline)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(10)
                }
                
                Spacer()
                
                // 복약 확인 버튼
                VStack(spacing: 15) {
                    Button(action: {
                        confirmMedication()
                    }) {
                        HStack {
                            if isConfirming {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                            }
                            Text(isConfirming ? "확인 중..." : "복약 확인")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                    .disabled(isConfirming)
                    
                    Button(action: {
                        snoozeMedication()
                    }) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title2)
                            Text("5분 후 다시")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .disabled(isConfirming)
                }
                .padding(.horizontal, 30)
            }
            .padding(.vertical, 40)
            .navigationTitle("복약 알림")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("닫기") {
                dismiss()
            })
        }
    }
    
    private func confirmMedication() {
        isConfirming = true
        Task {
            await store.confirmMedication(alarmId: alarm.id, leds: alarm.leds)
            DispatchQueue.main.async {
                isConfirming = false
                dismiss()
            }
        }
    }
    
    private func snoozeMedication() {
        // 5분 후 다시 알림
        let content = UNMutableNotificationContent()
        content.title = "💊 복약 시간 (스누즈)"
        content.body = "\(alarm.name.isEmpty ? "알람" : alarm.name) • LED \(alarm.leds.sorted().map(String.init).joined(separator: ", "))"
        content.sound = .default
        content.categoryIdentifier = "MEDICATION_ALARM"
        content.userInfo = [
            "alarmId": alarm.id,
            "leds": alarm.leds,
            "alarmName": alarm.name
        ]
        
        let trigger = UNTimeIntervalNotificaationTrigger(timeInterval: 300, repeats: false) // 5분 후
        let request = UNNotificationRequest(
            identifier: "snooze_\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("스누즈 알림 설정 오류: \(error)")
            }
        }
        
        dismiss()
    }
}


// ====== GLOBAL STORE ACCESS ======
class GlobalStore {
    static var shared: Store?
}
