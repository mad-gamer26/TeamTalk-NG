/*
 * Copyright (c) 2005-2018, BearWare.dk
 * 
 * Contact Information:
 *
 * Bjoern D. Rasmussen
 * Kirketoften 5
 * DK-8260 Viby J
 * Denmark
 * Email: contact@bearware.dk
 * Phone: +45 20 20 54 59
 * Web: http://www.bearware.dk
 *
 * This source code is part of the TeamTalk SDK owned by
 * BearWare.dk. Use of this file, or its compiled unit, requires a
 * TeamTalk SDK License Key issued by BearWare.dk.
 *
 * The TeamTalk SDK License Agreement along with its Terms and
 * Conditions are outlined in the file License.txt included with the
 * TeamTalk SDK distribution.
 *
 */

import UIKit

class TextMsgTableCell : UITableViewCell {
    
    @IBOutlet weak var messageTextView: UITextView!

    @IBOutlet weak var authorLabel: UILabel!

    private var didConfigureMultilineLayout = false
    var activationHandler: (() -> Void)?

    override func awakeFromNib() {
        super.awakeFromNib()
        configureMultilineLayout()
    }

    private func configureMultilineLayout() {
        guard didConfigureMultilineLayout == false else { return }
        didConfigureMultilineLayout = true

        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.numberOfLines = 0
        messageTextView.isScrollEnabled = false
        messageTextView.isUserInteractionEnabled = false
        messageTextView.textContainer.maximumNumberOfLines = 0
        messageTextView.setContentCompressionResistancePriority(.required, for: .vertical)
        messageTextView.setContentHuggingPriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            authorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            authorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            authorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            messageTextView.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 2),
            messageTextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            messageTextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            messageTextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
    }

    override func accessibilityActivate() -> Bool {
        guard let activationHandler else {
            return super.accessibilityActivate()
        }
        activationHandler()
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        activationHandler = nil
    }

}
