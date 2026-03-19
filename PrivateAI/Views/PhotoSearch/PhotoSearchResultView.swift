import SwiftUI
import Photos

/// Grid view showing photo search results. Tapping a photo opens it in the Photos app.
struct PhotoSearchResultView: View {
    let assetIDs: [String]
    @State private var thumbnails: [String: UIImage] = [:]
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if assetIDs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("没有找到匹配的照片")
                            .foregroundColor(.secondary)
                        Text("试试换个描述方式？")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(assetIDs, id: \.self) { id in
                                PhotoThumbnailCell(
                                    assetID: id,
                                    thumbnail: thumbnails[id],
                                    onTap: { openInPhotos(assetID: id) }
                                )
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .navigationTitle("搜索结果（\(assetIDs.count) 张）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { loadThumbnails() }
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        let targetSize = CGSize(width: 200, height: 200)

        fetchResult.enumerateObjects { asset, _, _ in
            manager.requestImage(for: asset, targetSize: targetSize,
                                 contentMode: .aspectFill, options: options) { image, _ in
                if let image {
                    DispatchQueue.main.async {
                        thumbnails[asset.localIdentifier] = image
                    }
                }
            }
        }
    }

    // MARK: - Open in Photos

    private func openInPhotos(assetID: String) {
        // Construct phobos:// URL or use a share sheet
        // The standard way to open a specific photo in Photos app:
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }

        // Use PHAsset.localIdentifier to navigate — open Photos app
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        if let date = asset.creationDate {
            // Open Photos app to the date of the photo
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        }
    }
}

// MARK: - Thumbnail Cell

struct PhotoThumbnailCell: View {
    let assetID: String
    let thumbnail: UIImage?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .aspectRatio(1, contentMode: .fill)
                        .overlay {
                            ProgressView()
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inline Chat Photo Results (compact strip)

struct PhotoResultsStrip: View {
    let assetIDs: [String]
    let onShowAll: () -> Void
    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "photo.stack")
                    .foregroundColor(Color("AccentPrimary"))
                Text("找到 \(assetIDs.count) 张照片")
                    .font(.subheadline.bold())
                Spacer()
                Button("查看全部") { onShowAll() }
                    .font(.caption)
                    .foregroundColor(Color("AccentPrimary"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(assetIDs.prefix(10), id: \.self) { id in
                        if let img = thumbnails[id] {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.systemGray5))
                                .frame(width: 72, height: 72)
                        }
                    }
                    if assetIDs.count > 10 {
                        VStack {
                            Text("+\(assetIDs.count - 10)")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 72, height: 72)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { loadThumbnails() }
    }

    private func loadThumbnails() {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false

        let ids = Array(assetIDs.prefix(10))
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let targetSize = CGSize(width: 150, height: 150)

        fetchResult.enumerateObjects { asset, _, _ in
            manager.requestImage(for: asset, targetSize: targetSize,
                                 contentMode: .aspectFill, options: options) { image, _ in
                if let image {
                    DispatchQueue.main.async {
                        thumbnails[asset.localIdentifier] = image
                    }
                }
            }
        }
    }
}
