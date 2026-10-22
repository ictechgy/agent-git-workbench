import SwiftUI

struct ReviewLayout: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var layout: LayoutPreferences
  let drag: DockDragSession
  var body: some View { DockWorkspace(store: store, layout: layout, drag: drag) }
}
