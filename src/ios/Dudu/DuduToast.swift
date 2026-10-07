//
//  DuduToast.swift
//  Dudu
//
//  嘟嘟自己的轻提示 —— UIKit 实现，奶白胶囊 + 棕黑字（定妆色板）。
//  引擎层通过 DuduToast.show(_:) 触发。

import UIKit

enum DuduToast {
    /// Show a toast with an already-localized message. Safe from any thread.
    static func show(_ message: String, duration: TimeInterval = 1.6,
                     systemImage: String = "checkmark.circle.fill") {
        if Thread.isMainThread {
            present(message, duration: duration, systemImage: systemImage)
        } else {
            DispatchQueue.main.async { present(message, duration: duration, systemImage: systemImage) }
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private static func present(_ message: String, duration: TimeInterval, systemImage: String) {
        guard let window = keyWindow() else { return }

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor(red: 0x8B / 255, green: 0x73 / 255, blue: 0x6C / 255, alpha: 1)
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let check = UIImageView(image: UIImage(systemName: systemImage))
        check.tintColor = UIColor(red: 0xEC / 255, green: 0xC7 / 255, blue: 0xD6 / 255, alpha: 1)
        check.contentMode = .scaleAspectFit
        check.translatesAutoresizingMaskIntoConstraints = false

        let capsule = UIView()
        capsule.backgroundColor = UIColor(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xEA / 255, alpha: 0.96)
        capsule.layer.cornerRadius = 18
        capsule.layer.cornerCurve = .continuous
        capsule.layer.borderWidth = 1
        capsule.layer.borderColor = UIColor(red: 0xF1 / 255, green: 0xE7 / 255, blue: 0xE2 / 255, alpha: 1).cgColor
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.alpha = 0

        capsule.addSubview(check)
        capsule.addSubview(label)
        window.addSubview(capsule)

        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 16),
            check.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),
            check.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -10),
            capsule.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -48),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 24),
            capsule.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -24),
        ])

        UIView.animate(withDuration: 0.25) { capsule.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: duration, options: [.curveEaseIn]) {
            capsule.alpha = 0
        } completion: { _ in
            capsule.removeFromSuperview()
        }
    }
}
