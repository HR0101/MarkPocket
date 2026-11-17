import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum DocumentPickerMode: Identifiable {
    case files(types: [UTType], allowsMultiple: Bool)
    case folder

    var id: String {
        switch self {
        case .files(_, let multi): return "files-\(multi)"
        case .folder: return "folder"
        }
    }
}

struct DocumentPickerSheet: UIViewControllerRepresentable {
    let mode: DocumentPickerMode
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller: UIDocumentPickerViewController
        switch mode {
        case .files(let types, let allowsMultiple):
            controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
            controller.allowsMultipleSelection = allowsMultiple
        case .folder:
            controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            controller.allowsMultipleSelection = false
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
