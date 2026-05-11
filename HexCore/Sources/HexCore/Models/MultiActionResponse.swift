import Foundation

public struct MultiActionResponse: Codable, Equatable, Sendable {
  public var actions: [ActionIntent]

  public var isSingleAction: Bool { actions.count == 1 }

  public init(actions: [ActionIntent]) {
    self.actions = actions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.actions = try container.decode([ActionIntent].self, forKey: .actions)
  }

  private enum CodingKeys: String, CodingKey {
    case actions
  }
}
