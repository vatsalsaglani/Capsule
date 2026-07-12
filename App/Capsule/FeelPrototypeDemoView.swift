#if DEBUG
import SwiftUI

/// The `#if DEBUG` feel-prototype window (P1B B2). Reuses `ContainersView`
/// verbatim against a `ScriptedDemoSession`'s fake-but-real pipeline — the
/// prototype and the shipping Containers screen are the same view code, so
/// the frame-by-frame review sets the actual craft bar rather than a
/// throwaway mockup.
struct FeelPrototypeDemoView: View {
    let demoSession: ScriptedDemoSession

    var body: some View {
        ContainersView(session: demoSession.session)
            .frame(minWidth: 640, minHeight: 420)
            .task { await demoSession.start() }
    }
}
#endif
