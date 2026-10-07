//
//  DuduColors.swift
//  Dudu
//
//  嘟嘟 UI 定妆色板 —— 唯一允许的颜色来源。
//  对应 ~/workspace/openmuse/design-tokens.css，App 内不许写硬编码色。

import SwiftUI

enum DuduColors {
    // 品牌四色
    static let brown = Color(hex: 0x8B736C)      // 棕黑：主文字
    static let pinkSoft = Color(hex: 0xFFE7E8)   // 浅粉：图标圆角底、点缀
    static let cream = Color(hex: 0xFBF8EA)      // 奶白：页面底色
    static let pink = Color(hex: 0xECC7D6)       // 粉：强调色

    // 语义色
    static let bg = cream                        // 页面背景
    static let card = Color.white                 // 卡片
    static let text = brown                       // 主文字
    static let textDim = Color(hex: 0xA89890)    // 弱文字
    static let accent = pink                      // 强调
    static let iconChip = pinkSoft                // 行样式图标底
    static let divider = Color(hex: 0xF1E7E2)    // 分隔线
    static let kitty = Color(hex: 0x2A2A2E)      // 小黑猫剪影

    // 字号（小巧）
    static let fontTitle: CGFloat = 15
    static let fontBody: CGFloat = 13
    static let fontCaption: CGFloat = 11

    // 圆角
    static let radiusCard: CGFloat = 16
    static let radiusChip: CGFloat = 12
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
