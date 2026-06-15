// MARK: - StatusBar
import SwiftUI

struct StatusBar: View {
    @State private var isEditing = false
    @State private var currentLocation = ""
    @State private var statusBarPosition: StatusBarPosition = .bottom

    var body: some View {
        VStack {
            if statusBarPosition == .top {
                HStack {
                    Text("Current Location: ")
                    if isEditing {
                        TextField("", text: $currentLocation)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .onAppear {
                                isEditing = true
                            }
                            .onDisappear {
                                isEditing = false
                            }
                    } else {
                        Text(currentLocation)
                            .onTapGesture {
                                isEditing = true
                            }
                    }
                }
                .padding()
            }
            Spacer()
            if statusBarPosition == .bottom {
                HStack {
                    Text("Current Location: ")
                    if isEditing {
                        TextField("", text: $currentLocation)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .onAppear {
                                isEditing = true
                            }
                            .onDisappear {
                                isEditing = false
                            }
                    } else {
                        Text(currentLocation)
                            .onTapGesture {
                                isEditing = true
                            }
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(10)
        .padding()
    }
}

enum StatusBarPosition {
    case top
    case bottom
}
