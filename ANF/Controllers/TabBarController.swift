// MARK: - TabBarController
import UIKit

class TabBarController: UIViewController {
    @IBOutlet weak var tableView: UITableView!
    var tabs: [Tab] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.delegate = self
        tableView.dataSource = self
    }
}

extension TabBarController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tabs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "TabCell", for: indexPath)
        cell.textLabel?.text = tabs[indexPath.row].name
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let tab = tabs[indexPath.row]
        if tab.isLocked {
            // Navigate to the locked tab's URL
        } else {
            // Navigate to the selected tab's URL
        }
    }
}
