import SwiftUI

struct LEDIndicator: View {
    let isBackingUp: Bool
    let size: CGFloat

    init(isBackingUp: Bool, size: CGFloat = 16) {
        self.isBackingUp = isBackingUp
        self.size = size
    }

    private var ledColor: Color {
        // Green = safe to disconnect (not backing up)
        // Red = backup in progress (do not disconnect)
        isBackingUp ? .red : .green
    }

    private var glowColor: Color {
        ledColor.opacity(0.6)
    }

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [glowColor, glowColor.opacity(0)]),
                        center: .center,
                        startRadius: size * 0.3,
                        endRadius: size * 0.8
                    )
                )
                .frame(width: size * 1.5, height: size * 1.5)

            // Main LED body
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            ledColor.opacity(0.9),
                            ledColor
                        ]),
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size
                    )
                )
                .frame(width: size, height: size)

            // Highlight/reflection
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.6),
                            Color.white.opacity(0)
                        ]),
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.4
                    )
                )
                .frame(width: size * 0.7, height: size * 0.7)
                .offset(x: -size * 0.1, y: -size * 0.1)

            // Subtle border for definition
            Circle()
                .stroke(ledColor.opacity(0.8), lineWidth: 0.5)
                .frame(width: size, height: size)
        }
    }
}

struct LEDIndicatorForMenuBar: View {
    let isBackingUp: Bool

    private var ledColor: Color {
        isBackingUp ? .red : .green
    }

    var body: some View {
        ZStack {
            // Glow effect
            Circle()
                .fill(ledColor.opacity(0.4))
                .frame(width: 14, height: 14)
                .blur(radius: 2)

            // Main LED
            Circle()
                .fill(ledColor)
                .frame(width: 10, height: 10)

            // Highlight
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.5),
                            Color.clear
                        ]),
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 4
                    )
                )
                .frame(width: 8, height: 8)
                .offset(x: -1, y: -1)
        }
        .frame(width: 18, height: 18)
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 30) {
            VStack {
                LEDIndicator(isBackingUp: false, size: 24)
                Text("Safe")
                    .font(.caption)
            }
            VStack {
                LEDIndicator(isBackingUp: true, size: 24)
                Text("Backing Up")
                    .font(.caption)
            }
        }

        Divider()

        HStack(spacing: 30) {
            VStack {
                LEDIndicatorForMenuBar(isBackingUp: false)
                Text("Menu Bar - Safe")
                    .font(.caption)
            }
            VStack {
                LEDIndicatorForMenuBar(isBackingUp: true)
                Text("Menu Bar - Busy")
                    .font(.caption)
            }
        }
    }
    .padding(40)
    .background(Color(NSColor.windowBackgroundColor))
}
