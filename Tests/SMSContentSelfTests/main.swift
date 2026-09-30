import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func phones(_ result: SMSContentDetection) -> [String] {
    result.links.compactMap {
        if case .phoneNumber(let number) = $0.destination { return number }
        return nil
    }
}

func websites(_ result: SMSContentDetection) -> [URL] {
    result.links.compactMap {
        if case .website(let url) = $0.destination { return url }
        return nil
    }
}

let mixedText = "🔐【CellDockPlus】验证码 482913，请访问 https://example.com/13800138000?code=123456，或联系 13800138000。"
let mixed = SMSContentDetector.detect(in: mixedText)
expect(mixed.verificationCode?.code == "482913", "Mixed SMS must retain the actual OTP")
expect(phones(mixed) == ["13800138000"], "Digits inside a URL or OTP must not become phone links")
expect(websites(mixed).map(\.absoluteString) == ["https://example.com/13800138000?code=123456"], "URL query and path must be preserved, excluding Chinese punctuation")
for link in mixed.links {
    expect(Range(link.range, in: mixedText) != nil, "UTF-16 ranges must map correctly after emoji and Chinese text")
}
if let code = mixed.verificationCode, let range = Range(code.range, in: mixedText) {
    expect(String(mixedText[range]) == code.code, "OTP range must identify the original code")
} else {
    fatalError("Missing OTP range")
}

let formatted = SMSContentDetector.detect(in: "联系 +86 138 0013 8000 或 (415) 555-2671。")
expect(phones(formatted) == ["+8613800138000", "4155552671"], "Formatted international and local numbers must prefill clean dial strings")
expect(formatted.verificationCode == nil, "Phone-only SMS must not show an OTP")

let bareDomains = SMSContentDetector.detect(in: "请访问 www.example.com 和 example.org/path。")
expect(websites(bareDomains).count == 2, "Domains without a scheme must be recognized")
expect(websites(bareDomains).allSatisfy(SMSContentDetector.isWebsite), "Detected domains must have web schemes")

for text in ["验证码 12345678", "7315 是您的登录验证码，请勿告诉他人。", "Your verification code is A7K9Q2."] {
    let result = SMSContentDetector.detect(in: text)
    expect(result.verificationCode != nil, "Numeric and alphanumeric OTPs must be recognized")
    expect(phones(result).isEmpty, "OTP must not also become a phone link")
}

for text in ["验证码已发送至 138-0013-8000", "验证链接 https://example.com/?code=123456", "订单号 482913 已发货。"] {
    expect(SMSContentDetector.detect(in: text).verificationCode == nil, "Phone fragments, URL parameters and ordinary order numbers must not become OTPs")
}

let ordinary = SMSContentDetector.detect(in: "订单号 202609061234567890，金额 1234.56 元，日期 2026-09-06。")
expect(ordinary.links.isEmpty && ordinary.verificationCode == nil, "Dates, prices and long order IDs must remain plain text")
let repeated = SMSContentDetector.detect(in: "13800138000，13800138000；https://example.com https://example.com")
expect(repeated.links.count == 4, "Every occurrence must remain independently clickable")
expect(Set(repeated.links.map(\.range.location)).count == 4, "Repeated values must retain distinct ranges")

for value in ["tel:13800138000", "mailto:test@example.com", "file:///tmp/test", "javascript:alert(1)", "https:"] {
    expect(!SMSContentDetector.isWebsite(URL(string: value)!), "Only HTTP(S) websites may open externally")
}
let email = SMSContentDetector.detect(in: "发邮件至 test@example.com。")
expect(email.links.isEmpty, "Email must not be treated as a website")
expect(SMSContentDetector.detect(in: "").links.isEmpty, "Empty SMS must be handled")
print("SMS content detection self-tests passed")
