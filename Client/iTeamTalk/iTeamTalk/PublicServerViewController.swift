import UIKit

final class PublicServerViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Unavailable", comment: "settings")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 0
    }
}
