import UIKit

enum CompactUI {
    static var backgroundColor: UIColor {
        if #available(iOS 13.0, *) {
            return .systemGroupedBackground
        }
        return UIColor(white: 0.96, alpha: 1.0)
    }

    static var secondaryBackgroundColor: UIColor {
        if #available(iOS 13.0, *) {
            return .secondarySystemGroupedBackground
        }
        return .white
    }

    static var secondaryTextColor: UIColor {
        if #available(iOS 13.0, *) {
            return .secondaryLabel
        }
        return .darkGray
    }

    static var accentColor: UIColor {
        return UIColor(red: 0.0, green: 0.38, blue: 0.75, alpha: 1.0)
    }

    static func apply(to viewController: UIViewController, title: String? = nil) {
        if let title = title {
            viewController.title = title
            viewController.navigationItem.title = title
        }

        viewController.view.backgroundColor = backgroundColor
        viewController.navigationController?.navigationBar.prefersLargeTitles = false
        viewController.navigationController?.navigationBar.tintColor = accentColor
        viewController.tabBarController?.tabBar.tintColor = accentColor
    }

    static func apply(to tableView: UITableView) {
        tableView.backgroundColor = backgroundColor
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 16)
        tableView.tableFooterView = UIView(frame: .zero)

        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
    }

    static func applyPrimaryButton(_ button: UIButton, title: String? = nil) {
        if let title = title {
            button.setTitle(title, for: .normal)
        }

        button.backgroundColor = accentColor
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    }

    static func stylePrimaryLabel(_ label: UILabel?) {
        label?.font = UIFont.preferredFont(forTextStyle: .body)
        label?.adjustsFontForContentSizeCategory = true
        label?.numberOfLines = 1
    }

    static func styleSecondaryLabel(_ label: UILabel?) {
        label?.font = UIFont.preferredFont(forTextStyle: .caption1)
        label?.textColor = secondaryTextColor
        label?.adjustsFontForContentSizeCategory = true
        label?.numberOfLines = 1
    }

    static func setEmptyState(on tableView: UITableView, title: String, message: String) {
        let container = UIView(frame: tableView.bounds)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = secondaryTextColor
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        tableView.backgroundView = container
    }

    static func clearEmptyState(on tableView: UITableView) {
        tableView.backgroundView = nil
    }
}
