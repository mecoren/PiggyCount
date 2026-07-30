//
//  PiggyCountWidgetBundle.swift
//  PiggyCountWidget
//
//  Created by matrix on 2025/11/5.
//

import WidgetKit
import SwiftUI

@main
struct PiggyCountWidgetBundle: WidgetBundle {
    var body: some Widget {
        // 现有：收支速览（中号），iOS kind/图 key 全部保持不变，存量桌面
        // 放置不受影响。
        PiggyCountWidget()
        // 新增（Phase D）：净资产 / 快速记账 / 预算进度 / 最近交易 /
        // 综合仪表盘，详见各自 .swift 文件与 lib/widget/widget_spec.dart。
        PiggyCountNetWorthWidget()
        PiggyCountQuickAddWidget()
        PiggyCountBudgetWidget()
        PiggyCountRecentWidget()
        PiggyCountDashboardWidget()
    }
}
