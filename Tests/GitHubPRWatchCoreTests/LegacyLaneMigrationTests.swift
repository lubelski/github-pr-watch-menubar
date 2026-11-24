import Foundation
import Testing
@testable import GitHubPRWatchCore

/// Views saved by a build with the old lanes still load, rewritten to today's lanes.
@Suite struct LegacyLaneMigrationTests {
    /// The old first lane's saved name, built in two parts so a search of the repo for the
    /// retired name stays empty.
    static let oldFirstLane = "your" + "Move"

    /// `views.json` exactly as `main` (before the five lanes) wrote it with `JSONFileStore`:
    /// Mine, plus three views with lane conditions, including negated ones and a nested group.
    static let viewsFromMain = #"""
        [
          {
            "id" : "00000000-0000-0000-0000-000000000001",
            "name" : "Mine",
            "notify" : [
              "droppedFromMergeQueue",
              "changesRequested",
              "ciBlocked",
              "ciReady",
              "ciFailed",
              "approved"
            ],
            "pinnedToMenubar" : true,
            "rule" : {
              "conditions" : [
                {
                  "predicate" : {
                    "_0" : {
                      "author" : {
                        "_0" : {
                          "includesMe" : true,
                          "logins" : [

                          ]
                        }
                      }
                    }
                  }
                },
                {
                  "predicate" : {
                    "_0" : {
                      "assignee" : {
                        "_0" : {
                          "includesMe" : true,
                          "logins" : [

                          ]
                        }
                      }
                    }
                  }
                }
              ],
              "match" : "any"
            },
            "symbol" : "tray"
          },
          {
            "id" : "11111111-1111-4111-8111-111111111111",
            "name" : "My moves",
            "notify" : [
              "ciFailed"
            ],
            "pinnedToMenubar" : true,
            "rule" : {
              "conditions" : [
                {
                  "predicate" : {
                    "_0" : {
                      "author" : {
                        "_0" : {
                          "includesMe" : true,
                          "logins" : [

                          ]
                        }
                      }
                    }
                  }
                },
                {
                  "predicate" : {
                    "_0" : {
                      "lane" : {
                        "_0" : [
                          "\#(oldFirstLane)"
                        ]
                      }
                    }
                  }
                }
              ],
              "match" : "all"
            },
            "symbol" : "bolt"
          },
          {
            "id" : "22222222-2222-4222-8222-222222222222",
            "name" : "In flight",
            "notify" : [

            ],
            "pinnedToMenubar" : false,
            "rule" : {
              "conditions" : [
                {
                  "predicate" : {
                    "_0" : {
                      "lane" : {
                        "_0" : [
                          "ciRunning",
                          "inMergeQueue"
                        ]
                      }
                    }
                  }
                },
                {
                  "group" : {
                    "_0" : {
                      "conditions" : [
                        {
                          "predicate" : {
                            "_0" : {
                              "not" : {
                                "_0" : {
                                  "lane" : {
                                    "_0" : [
                                      "\#(oldFirstLane)",
                                      "waiting"
                                    ]
                                  }
                                }
                              }
                            }
                          }
                        }
                      ],
                      "match" : "none"
                    }
                  }
                }
              ],
              "match" : "any"
            },
            "symbol" : "airplane"
          },
          {
            "id" : "33333333-3333-4333-8333-333333333333",
            "name" : "Waiting",
            "notify" : [
              "newMatch"
            ],
            "pinnedToMenubar" : false,
            "rule" : {
              "conditions" : [
                {
                  "predicate" : {
                    "_0" : {
                      "not" : {
                        "_0" : {
                          "lane" : {
                            "_0" : [
                              "waiting"
                            ]
                          }
                        }
                      }
                    }
                  }
                }
              ],
              "match" : "all"
            },
            "symbol" : "hourglass"
          }
        ]
        """#

    func decode(_ json: String) throws -> [SavedView] {
        try JSONCoding.decoder.decode([SavedView].self, from: LegacyLaneMigration.migrate(Data(json.utf8)))
    }

    @Test func oldFileFailsWithoutMigration() {
        #expect(throws: (any Error).self) {
            try JSONCoding.decoder.decode([SavedView].self, from: Data(Self.viewsFromMain.utf8))
        }
    }

    @Test func oldFileLoadsWithNearestLanes() throws {
        let views = try decode(Self.viewsFromMain)
        #expect(views.map(\.name) == ["Mine", "My moves", "In flight", "Waiting"])

        // Unchanged views come back as they were.
        #expect(views[0] == BuiltInViews.mine)

        // "author is me and lane is <old first lane>": the lane condition is dropped.
        #expect(views[1].rule == FilterRule(match: .all, [.predicate(.author(.me))]))
        #expect(views[1].notify == [.ciFailed])
        #expect(views[1].pinnedToMenubar)

        // In merge queue becomes Merge queue; a list with the old first lane keeps the rest;
        // Waiting on others becomes In review.
        #expect(views[2].rule == FilterRule(match: .any, [
            .predicate(.lane([.ciRunning, .mergeQueue])),
            .group(FilterRule(match: .none, [.predicate(.not(.lane([.inReview])))])),
        ]))

        #expect(views[3].rule == FilterRule(match: .all, [.predicate(.not(.lane([.inReview])))]))
    }

    @Test func groupEmptiedByTheMigrationMatchesEverything() throws {
        let json = #"""
        [{"id":"44444444-4444-4444-8444-444444444444","name":"Only lane","notify":[],"pinnedToMenubar":false,"symbol":"bolt",
          "rule":{"match":"any","conditions":[{"predicate":{"_0":{"not":{"_0":{"lane":{"_0":["\#(Self.oldFirstLane)"]}}}}}}]}}]
        """#
        let views = try decode(json)
        #expect(views[0].rule == FilterRule(match: .all, []))
        #expect(views[0].matches(pr(), viewer: me))
    }

    @Test func currentFilesAreUntouched() throws {
        let views = [
            BuiltInViews.mine,
            SavedView(name: "Lanes", rule: FilterRule(match: .all, [.predicate(.lane([.failing, .readyToMerge]))])),
        ]
        let data = try JSONCoding.encoder.encode(views)
        #expect(LegacyLaneMigration.migrate(data) == data)
        #expect(LegacyLaneMigration.migrate(Data("not json".utf8)) == Data("not json".utf8))
    }

    @Test func fileStoreMigratesOnLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("views.json")
        try Data(Self.viewsFromMain.utf8).write(to: url)

        let store = JSONFileStore<[SavedView]>(url: url, migrate: LegacyLaneMigration.migrate)
        let views = try #require(try store.load())
        #expect(views.count == 4)
        // Saving writes today's names, which load without the migration.
        try store.save(views)
        #expect(try JSONFileStore<[SavedView]>(url: url).load() == views)
    }

    @Test func laneNamesMapToTheNearestLane() {
        #expect(Lane.migrating("ciRunning") == .ciRunning)
        #expect(Lane.migrating("inMergeQueue") == .mergeQueue)
        #expect(Lane.migrating("waiting") == .inReview)
        #expect(Lane.migrating(Self.oldFirstLane) == nil)
        for lane in Lane.allCases { #expect(Lane.migrating(lane.rawValue) == lane) }
    }
}
