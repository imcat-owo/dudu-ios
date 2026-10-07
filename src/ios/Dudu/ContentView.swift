//
//  ContentView.swift
//  Dudu
//
//  嘟嘟主界面占位 —— 按定妆色板（奶白底、棕黑小字）绘制。
//  引擎零件已随包编译，界面将按「嘟嘟 HTML」定妆一块一块接上来。

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            DuduColors.bg
                .ignoresSafeArea()

            VStack(spacing: 12) {
                // 实心小黑猫剪影（定妆：thinking/工具入口的视觉符号）
                Image(systemName: "cat.fill")
                    .font(.system(size: 40))
                    .foregroundColor(DuduColors.kitty)

                Text("嘟嘟")
                    .font(.system(size: DuduColors.fontTitle + 4, weight: .semibold))
                    .foregroundColor(DuduColors.text)

                Text("原生壳已就位，引擎零件装载中")
                    .font(.system(size: DuduColors.fontBody))
                    .foregroundColor(DuduColors.textDim)

                RoundedRectangle(cornerRadius: DuduColors.radiusCard)
                    .fill(DuduColors.card)
                    .frame(height: 56)
                    .overlay(
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: DuduColors.radiusChip)
                                .fill(DuduColors.iconChip)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(DuduColors.pink)
                                )
                            Text("能打开，不闪退")
                                .font(.system(size: DuduColors.fontBody))
                                .foregroundColor(DuduColors.text)
                        }
                    )
                    .padding(.horizontal, 24)
            }
        }
    }
}

#Preview {
    ContentView()
}
