import SwiftUI

struct ModeSelectorView: View {
    @AppStorage("productMode") private var modeRaw: String = ProductMode.ppsr.rawValue
    @Binding var hasSelectedMode: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image("SplitScreenBG")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                HStack(spacing: 0) {
                    Button {
                        modeRaw = ProductMode.ppsr.rawValue
                        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                            hasSelectedMode = true
                        }
                    } label: {
                        ppsrSide
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                    .buttonStyle(.plain)

                    Button {
                        modeRaw = ProductMode.login.rawValue
                        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                            hasSelectedMode = true
                        }
                    } label: {
                        loginSide
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var ppsrSide: some View {
        ZStack {
            Color.green.opacity(0.15)

            VStack(spacing: 20) {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
                    .shadow(color: .green, radius: 10)

                Text("PPSR\nCarCheck")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 4)

                Text("VIN automation\n& card testing")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black, radius: 2)

                Image(systemName: "chevron.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 8)
            }
            .padding()
        }
    }

    private var loginSide: some View {
        ZStack {
            Color.red.opacity(0.15)

            Rectangle()
                .fill(.white.opacity(0.03))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(width: 1)
                }

            VStack(spacing: 20) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
                    .shadow(color: .red, radius: 10)

                Text("Joe &\nIgnition")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 4)

                Text("Login testing\n& automation")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black, radius: 2)

                Image(systemName: "chevron.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 8)
            }
            .padding()
        }
    }
}
