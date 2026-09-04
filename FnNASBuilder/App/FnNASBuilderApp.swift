import SwiftUI

@main
struct FnNASBuilderApp: App {
    @StateObject private var model = BuilderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // 给窗口保留足够的初始工作空间，同时允许用户自由缩放。
                .frame(minWidth: 1_080, minHeight: 720)
        }
        // 由系统提供标准标题栏，避免将内容尺寸锁定为窗口大小。
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_280, height: 820)
    }
}
