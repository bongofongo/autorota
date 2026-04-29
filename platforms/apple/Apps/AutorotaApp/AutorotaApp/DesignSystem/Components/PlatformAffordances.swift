import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension View {
    @ViewBuilder
    func appDecimalKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func appEmailKeyboardConfig() -> some View {
        #if canImport(UIKit)
        self.keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        #else
        self
        #endif
    }

    @ViewBuilder
    func appFormGroupedStyle() -> some View {
        #if os(macOS)
        self.formStyle(.grouped)
        #else
        self
        #endif
    }

    @ViewBuilder
    func appSheetMacFrame(
        minWidth: CGFloat,
        idealWidth: CGFloat,
        minHeight: CGFloat,
        idealHeight: CGFloat
    ) -> some View {
        #if os(macOS)
        self.frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            minHeight: minHeight,
            idealHeight: idealHeight
        )
        #else
        self
        #endif
    }

    func dismissesKeyboardOnTap() -> some View {
        #if canImport(UIKit)
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        #else
        self
        #endif
    }
}

func appOpenURL(_ url: URL) {
    #if canImport(UIKit)
    UIApplication.shared.open(url)
    #elseif canImport(AppKit)
    NSWorkspace.shared.open(url)
    #endif
}
