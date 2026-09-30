import SwiftUI

struct ContentView: View {
    enum Tab { case pids, dashboard, export }
    @State private var selection: Tab = .pids

    var body: some View {
        TabView(selection: $selection) {
            // ino の onStartMonitoring と同様、Start 押下でモニター画面へ遷移する
            PidSelectView(onStarted: { selection = .dashboard })
                .tabItem { Label("PIDs", systemImage: "checklist") }
                .tag(Tab.pids)
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge") }
                .tag(Tab.dashboard)
            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(Tab.export)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GatewayBLEManager())
}
