//
//  HomeView.swift
//  MacPearl
//
//  Created by Steven Ha on 9/29/26.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "faceid")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("MacPearl")
                .font(.title)
                .fontWeight(.semibold)

            Text("Camera preview is the first milestone.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 360)
    }
}

#Preview {
    HomeView()
}
