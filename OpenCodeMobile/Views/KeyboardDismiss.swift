import SwiftUI

/// Tapping anywhere outside an active text field dismisses the keyboard.
/// Mirrors the ChatView pattern: a transparent hit-layer at the ZStack
/// bottom catches taps on blank areas; interactive views (buttons, text
/// fields, scroll views) still win their own hit tests.
struct DismissKeyboardOnTapOutside: ViewModifier {
    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { hideKeyboard() }
            content
        }
    }
}

extension View {
    func dismissKeyboardOnTapOutside() -> some View {
        modifier(DismissKeyboardOnTapOutside())
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
