import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    
    var body: some View {
        HStack(spacing:30) {
            NavigationStack {
                VStack {
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("👋手势取景框")
                            .font(.largeTitle.bold())
                        Text("进入沉浸式空间，使用双手捏合，拍照")
                            .foregroundStyle(.secondary)
                        ToggleImmersiveSpaceButton()
                    }
                    .padding()
                    .padding(.bottom, 82)
                    Spacer()
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.spring) {
                                showSettings.toggle()
                            }
                        } label: {
                            Label("设置", systemImage: "gear")
                        }
                    }
                }
            }
            .glassBackgroundEffect()
            if showSettings {
                SettingsView(dismiss:{
                    withAnimation(.spring) {
                        showSettings = false
                    }
                })
                    .frame(width: 320)
                    .glassBackgroundEffect()
                    // 从背后推入推出
                    .transition(.modifier(active: MoveInFromBackModifier(offset: true), identity: MoveInFromBackModifier(offset: false)).combined(with: .opacity))
            }
        }
    }
}

// 设置页面
struct SettingsView: View {
    var dismiss:() -> Void
    @AppStorage("photoPresentationMode") private var photoPresentationMode: PhotoThreeDimensionalEffectMode = .stereo
    
    var body: some View {
        NavigationStack {
            VStack {
                Form {
                    Picker("照片呈现", systemImage: "photo.stack", selection: $photoPresentationMode) {
                        Section(header: Text("平面照片")) {
                            Text(PhotoThreeDimensionalEffectMode.left.displayName).tag(PhotoThreeDimensionalEffectMode.left)
                            Text(PhotoThreeDimensionalEffectMode.right.displayName).tag(PhotoThreeDimensionalEffectMode.right)
                        }
                        Text(PhotoThreeDimensionalEffectMode.stereo.displayName).tag(PhotoThreeDimensionalEffectMode.stereo)
                    }
                }
                Spacer()
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// Transition动画
fileprivate
struct MoveInFromBackModifier: ViewModifier {
    @PhysicalMetric(from:.meters)
    private var pointsPerMeter:CGFloat = 1
    let offset: Bool
 
    func body(content: Content) -> some View {
        // 从后方10cm移动到0cm，带有超出回弹
        content.offset(z: offset ? -0.1 * pointsPerMeter : 0)
    }
}

// Preview
#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
