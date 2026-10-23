import Combine

@MainActor
public final class DiffPresentationModel: ObservableObject {
  @Published public var onlyChangedHunks = false
  public init() {}
}
