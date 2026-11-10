import Foundation

// MARK: - Lightweight in-app localization
//
// Keys are the English strings themselves; missing keys fall back to English.
// The language switches live (no relaunch): AppState owns the selection and
// the root view rebuilds on change.

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"
    case spanish = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        case .spanish: return "Español"
        }
    }

    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US")
        case .chinese: return Locale(identifier: "zh_Hans")
        case .spanish: return Locale(identifier: "es_ES")
        }
    }
}

/// Translate a UI string. Call sites use the English text as the key.
func tr(_ key: String) -> String {
    L10n.translate(key)
}

/// Translate a format string ("Save %d holdings") and apply arguments.
func trf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.translate(key), arguments: args)
}

enum L10n {
    /// Kept in sync by AppState; reads are main-thread (UI only).
    nonisolated(unsafe) static var current: AppLanguage = .english

    static func translate(_ key: String) -> String {
        switch current {
        case .english: return key
        case .chinese: return zh[key] ?? key
        case .spanish: return es[key] ?? key
        }
    }

    // MARK: 中文

    static let zh: [String: String] = [
        // Chrome & commands
        "Portfolio": "投资组合", "Settings": "设置",
        "Import Holdings Screenshot…": "导入持仓截图…",
        "Import screenshot": "导入截图",
        "Drop screenshots to import": "拖放截图以导入",

        // Common verbs
        "Cancel": "取消", "Save": "保存", "Done": "完成", "Close": "关闭", "Delete": "删除",

        // Portfolio
        "TOTAL VALUE": "持仓总值", "As of": "截至", "%d assets": "%d 项资产",
        "Allocation": "配置", "Holdings": "持仓", "Total": "合计", "Others": "其他",
        "Value": "市值", "Share": "占比", "Updated": "更新于", "Never updated": "从未更新",
        "no valuation": "无估值", "Amount": "金额",
        "Update balance…": "更新余额…", "Update balance": "更新余额",
        "Delete holding": "删除持仓",
        "Delete “%@”?": "删除「%@」?",
        "Its valuation history is removed too.": "其估值历史也会一并删除。",
        "No holdings yet": "暂无持仓",
        "Import an Alipay screenshot to get started.": "导入一张支付宝持仓截图即可开始。",

        // Alipay OCR flow
        "Import Alipay holdings — screenshot OCR": "导入支付宝持仓——截图 OCR",
        "Drop Alipay holding screenshots here": "把支付宝持仓截图拖到这里",
        "Import holdings — screenshot OCR": "导入持仓——截图 OCR",
        "Drop Alipay or Binance holding screenshots here": "把支付宝或币安持仓截图拖到这里",
        "Cash (stablecoin) · excluded": "现金(稳定币) · 已排除",
        "No holdings parsed — check the screenshot shows the holdings list.": "未解析到持仓——请确认截图是持仓列表。",
        "No holdings were recognized. Try a clearer screenshot of the Alipay holdings list (持有页面) or the Binance asset list.": "未识别到持仓。请换一张更清晰的支付宝持有页面或币安资产列表截图。",
        "Asset name": "资产名称", "Alipay": "支付宝",
        "US equity": "美股", "China equity": "中国股票", "Other intl equity": "其他海外股票",
        "Gold": "黄金", "Exposure": "风险敞口", "Automatic": "自动",
        "Total value": "总资产",
        "Display currency for totals and allocation": "总览和配置的显示币种",
        "Import a holdings screenshot to get started.": "导入一张持仓截图即可开始。",
        "Choose images…": "选择图片…", "Paste from clipboard": "从剪贴板粘贴",
        "Recognizing text (Simplified Chinese + English)…": "文字识别中…",
        "Saving holdings…": "保存持仓中…", "Saved to Portfolio": "已存入投资组合",
        "Show detections": "显示识别框",
        "Save %d holdings": "保存 %d 项持仓",
        "Valuation date": "估值日期",
        "Try another image…": "换一张图…", "Fund name": "基金名称", "Code": "代码",
        "updates": "更新", "new": "新增", "Image %d": "图 %d",
        "Account total detected:": "识别到账户总额:",
        "Low-confidence fields (amber) — verify against the screenshot before saving.": "存在低置信度字段(黄色)——保存前请对照截图核对。",

        // Enum display names (data model)
        "Cash": "现金", "Payment": "支付", "Investment": "投资", "Crypto": "加密货币",
        "Other assets": "其他资产", "Money market": "货币基金", "Bonds": "债券",
        "Equity": "股票", "Mixed funds": "混合基金", "Other": "其他",
        "Income": "收入", "Expense": "支出", "Transfer": "转账", "Invest · buy": "投资买入",
        "Invest · sell": "投资卖出", "Repayment": "还款", "Adjustment": "调整",
        "Manual": "手动", "Alipay OCR": "支付宝 OCR", "Market data": "市场数据", "Sample data": "示例数据",
        "Weekly": "每周", "Monthly": "每月", "Quarterly": "每季", "Every 6 months": "每半年", "Yearly": "每年",
        "Imported": "已导入", "Partial": "部分", "Failed": "失败",

        // Settings
        "Language": "语言",
    ]

    // MARK: Español

    static let es: [String: String] = [
        // Chrome & commands
        "Portfolio": "Cartera", "Settings": "Ajustes",
        "Import Holdings Screenshot…": "Importar captura de posiciones…",
        "Import screenshot": "Importar captura",
        "Drop screenshots to import": "Suelta capturas para importar",

        // Common verbs
        "Cancel": "Cancelar", "Save": "Guardar", "Done": "Hecho", "Close": "Cerrar", "Delete": "Eliminar",

        // Portfolio
        "TOTAL VALUE": "VALOR TOTAL", "As of": "Al", "%d assets": "%d activos",
        "Allocation": "Asignación", "Holdings": "Posiciones", "Total": "Total", "Others": "Otros",
        "Value": "Valor", "Share": "Peso", "Updated": "Actualizado", "Never updated": "Nunca actualizado",
        "no valuation": "sin valoración", "Amount": "Importe",
        "Update balance…": "Actualizar saldo…", "Update balance": "Actualizar saldo",
        "Delete holding": "Eliminar posición",
        "Delete “%@”?": "¿Eliminar «%@»?",
        "Its valuation history is removed too.": "Su historial de valoraciones también se elimina.",
        "No holdings yet": "Sin posiciones aún",
        "Import an Alipay screenshot to get started.": "Importa una captura de Alipay para empezar.",

        // Alipay OCR flow
        "Import Alipay holdings — screenshot OCR": "Importar fondos de Alipay — OCR",
        "Drop Alipay holding screenshots here": "Suelta capturas de Alipay aquí",
        "Import holdings — screenshot OCR": "Importar posiciones — OCR",
        "Drop Alipay or Binance holding screenshots here": "Suelta capturas de Alipay o Binance aquí",
        "Cash (stablecoin) · excluded": "Efectivo (stablecoin) · excluido",
        "No holdings parsed — check the screenshot shows the holdings list.": "No se detectaron posiciones — verifica que la captura muestre la lista.",
        "No holdings were recognized. Try a clearer screenshot of the Alipay holdings list (持有页面) or the Binance asset list.": "No se reconocieron posiciones. Prueba una captura más clara de Alipay o de la lista de activos de Binance.",
        "Asset name": "Nombre del activo", "Alipay": "Alipay",
        "US equity": "Renta variable EE. UU.", "China equity": "Renta variable China", "Other intl equity": "Otra renta variable intl.",
        "Gold": "Oro", "Exposure": "Exposición", "Automatic": "Automático",
        "Total value": "Valor total",
        "Display currency for totals and allocation": "Moneda para totales y asignación",
        "Import a holdings screenshot to get started.": "Importa una captura de posiciones para empezar.",
        "Choose images…": "Elegir imágenes…", "Paste from clipboard": "Pegar del portapapeles",
        "Recognizing text (Simplified Chinese + English)…": "Reconociendo texto…",
        "Saving holdings…": "Guardando…", "Saved to Portfolio": "Guardado en Cartera",
        "Show detections": "Ver detecciones",
        "Save %d holdings": "Guardar %d posiciones",
        "Valuation date": "Fecha de valoración",
        "Try another image…": "Otra imagen…", "Fund name": "Nombre del fondo", "Code": "Código",
        "updates": "actualiza", "new": "nueva", "Image %d": "Imagen %d",
        "Account total detected:": "Total de cuenta detectado:",
        "Low-confidence fields (amber) — verify against the screenshot before saving.": "Hay campos de baja confianza (ámbar) — verifica con la captura antes de guardar.",

        // Enum display names (data model)
        "Cash": "Efectivo", "Payment": "Pago", "Investment": "Inversión", "Crypto": "Cripto",
        "Other assets": "Otros activos", "Money market": "Mercado monetario", "Bonds": "Bonos",
        "Equity": "Renta variable", "Mixed funds": "Fondos mixtos", "Other": "Otros",
        "Income": "Ingresos", "Expense": "Gasto", "Transfer": "Transferencia", "Invest · buy": "Inversión · compra",
        "Invest · sell": "Inversión · venta", "Repayment": "Reembolso", "Adjustment": "Ajuste",
        "Manual": "Manual", "Alipay OCR": "OCR de Alipay", "Market data": "Datos de mercado", "Sample data": "Datos de ejemplo",
        "Weekly": "Semanal", "Monthly": "Mensual", "Quarterly": "Trimestral", "Every 6 months": "Semestral", "Yearly": "Anual",
        "Imported": "Importado", "Partial": "Parcial", "Failed": "Fallido",

        // Settings
        "Language": "Idioma",
    ]
}
