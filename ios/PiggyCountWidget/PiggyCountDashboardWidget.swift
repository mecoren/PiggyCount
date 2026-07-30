//
//  PiggyCountDashboardWidget.swift
//  PiggyCountWidget
//
//  Created by matrix on 2026/7/19.
//

import WidgetKit
import SwiftUI
import UIKit

struct PiggyCountDashboardEntry: TimelineEntry {
    let date: Date
    let widgetImagePath: String
}

struct PiggyCountDashboardProvider: TimelineProvider {
    // 仅 systemLarge 一个尺寸（对应 `lib/widget/widget_spec.dart` 的
    // `dashboardLarge`），无需按 family 分支。
    private let imageKey = "widget_dashboard_large"

    func placeholder(in context: Context) -> PiggyCountDashboardEntry {
        PiggyCountDashboardEntry(
            date: Date(),
            // 添加页预览:用 bundle 内静态资产(见 WidgetPreviewAssets 注释)。
            widgetImagePath: WidgetPreviewAssets.path(forImageKey: imageKey)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PiggyCountDashboardEntry) -> ()) {
        // 添加页预览(isPreview):运行时图片在预览上下文读不到(App
        // Group 访问受限,添加页只会显示占位色块),改用 bundle 内静态
        // 预览资产,详见 WidgetPreviewAssets。
        if context.isPreview {
            completion(PiggyCountDashboardEntry(
                date: Date(),
                widgetImagePath: WidgetPreviewAssets.path(forImageKey: imageKey)))
            return
        }
        let userDefaults = UserDefaults(suiteName: "group.com.wait.piggycount")
        let imagePath = userDefaults?.string(forKey: imageKey) ?? ""
        let entry = PiggyCountDashboardEntry(date: Date(), widgetImagePath: imagePath)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let userDefaults = UserDefaults(suiteName: "group.com.wait.piggycount")
        let imagePath = userDefaults?.string(forKey: imageKey) ?? ""
        let entry = PiggyCountDashboardEntry(date: Date(), widgetImagePath: imagePath)

        // 设置30分钟后刷新
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct PiggyCountDashboardWidgetEntryView : View {
    var entry: PiggyCountDashboardProvider.Entry
    @Environment(\.widgetFamily) var widgetFamily

    // 分区点击(2026-07 真机反馈:底部画着「记一笔」却整块跳明细,点记一笔
    // 进了洞察页):上部主体 → 明细,底部快捷记账行 → 记支出。
    private let detailURL = URL(string: "piggycount://open?page=detail")!
    private let expenseURL = URL(string: "piggycount://new?type=expense")!

    var body: some View {
        if let uiImage = UIImage(contentsOfFile: entry.widgetImagePath) {
            GeometryReader { geometry in
                ZStack {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()

                    // 透明点击层:底部快捷记账行约占卡片高度 18%
                    // (与 DashboardView 底部按钮行的布局比例对齐)。
                    VStack(spacing: 0) {
                        Link(destination: detailURL) {
                            Color.clear
                        }
                        .frame(height: geometry.size.height * 0.82)
                        Link(destination: expenseURL) {
                            Color.clear
                        }
                    }
                }
            }
        } else {
            // Placeholder view when image is not available
            ZStack {
                Color(red: 1.0, green: 0.76, blue: 0.03)
                VStack {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                    Text("综合仪表盘")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .widgetURL(detailURL)
        }
    }
}

struct PiggyCountDashboardWidget: Widget {
    let kind: String = "PiggyCountDashboardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PiggyCountDashboardProvider()) { entry in
            if #available(iOS 17.0, *) {
                PiggyCountDashboardWidgetEntryView(entry: entry)
                    .containerBackground(for: .widget) {
                        Color.clear
                    }
            } else {
                PiggyCountDashboardWidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("综合仪表盘")
        .description("收支、趋势与最近交易一屏看尽")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()  // Remove default padding/margins in iOS 17+
    }
}
