//
//  SearchResultSourcesParsing.swift
//  Ryu
//
//  Created by Francesco on 13/07/24.
//

import UIKit
import SwiftSoup

extension SearchResultsViewController {
    func parseAnimeWorld(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select(".film-list .item")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("a.name").text()
                let imageUrl = try item.select("a.poster img").attr("src")
                let href = try item.select("a.poster").attr("href")
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeWorld: \(error.localizedDescription)")
            return []
        }
    }

    func parseGoGoAnime(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("ul.items li")
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                guard let linkElement = try item.select("a").first(),
                      let href = try? linkElement.attr("href"),
                      let imageUrl = try? linkElement.select("img").attr("src") else {
                          return nil
                      }

                var title = (try? linkElement.attr("title")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? linkElement.select("img").attr("alt")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? item.select("p.name > a").text()).flatMap { $0.isEmpty ? nil : $0 }
                ?? ""

                title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                guard !title.isEmpty else { return nil }
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing GoGoAnime: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeHeaven(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.info3.bc1 div.similarimg")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let linkElement = try item.select("a").first()
                let href = try linkElement?.attr("href") ?? ""
                var imageUrl = try linkElement?.select("img").attr("src") ?? ""
                if !imageUrl.isEmpty && !imageUrl.hasPrefix("http") {
                    imageUrl = "https://animeheaven.me/\(imageUrl)"
                }
                let title = try item.select("div.similarname a.c").text()
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeHeaven: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeFire(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.card-group div.row div.divCardUltimosEps")
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                guard let title = try item.select("div.text-block h3.animeTitle").first()?.text(),
                      let imageUrl = try item.select("article.card a img").first()?.attr("data-src"),
                      let href = try item.select("article.card a").first()?.attr("href")
                else { return nil }
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeFire: \(error.localizedDescription)")
            return []
        }
    }

    func parseKuramanime(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div#animeList div.col-lg-4")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("div.product__item__text h5 a").text()
                let imageUrl = try item.select("div.product__item__pic").attr("data-setbg")
                let href = try item.select("div.product__item a").attr("href")
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing Kuramanime: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnime3rb(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("section div.my-2")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("h2.pt-1").text()
                let imageUrl = try item.select("img").attr("src")
                let href = try item.select("a").first()?.attr("href") ?? ""
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing Anime3rb: \(error.localizedDescription)")
            return []
        }
    }

    // Renamed function
    func parseAniList(_ jsonString: String) -> [(title: String, imageUrl: String, href: String)] {
        do {

            guard let jsonData = jsonString.data(using: .utf8) else {
                print("Error converting JSON string to Data")
                return []
            }

            let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]

            guard let animes = json?["animes"] as? [[String: Any]] else {
                print("Error extracting 'animes' array from JSON")
                return []
            }

            return animes.map { anime -> (title: String, imageUrl: String, href: String) in
                let title = anime["name"] as? String ?? "Unknown Title"
                let imageUrl = anime["poster"] as? String ?? ""
                let href = anime["id"] as? String ?? ""
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AniList JSON: \(error.localizedDescription)") // Updated error message
            return []
        }
    }
    func parseAnilibria(_ jsonString: String) -> [(title: String, imageUrl: String, href: String)] {
        guard let jsonData = jsonString.data(using: .utf8) else {
            return []
        }

        do {
            guard let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
                  let list = jsonObject["list"] as? [[String: Any]] else {
                return []
            }

            return list.compactMap { anime -> (title: String, imageUrl: String, href: String)? in
                guard let id = anime["id"] as? Int,
                      let names = anime["names"] as? [String: Any],
                      let posters = anime["posters"] as? [String: Any],
                      let mediumPoster = posters["medium"] as? [String: Any],
                      let imageUrl = mediumPoster["url"] as? String else {
                    return nil
                }

                let title = (names["ru"] as? String) ?? (names["en"] as? String) ?? "Unknown Title"
                let imageURL = "https://anilibria.tv/" + imageUrl
                let href = String(id)

                return (title: title, imageUrl: imageURL, href: href)
            }
        } catch {
            print("Error parsing Anilibria JSON: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeSRBIJA(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.ani-wrap div.ani-item")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("h3.ani-title").text()

                let srcset = try item.select("img").attr("srcset")
                let imageUrl = srcset.components(separatedBy: ", ")
                    .last?
                    .components(separatedBy: " ")
                    .first ?? ""

                let imageURL = "https://www.animesrbija.com" + imageUrl

                let hrefBase = try item.select("a").first()?.attr("href") ?? ""
                let href = "https://www.animesrbija.com" + hrefBase

                return (title: title, imageUrl: imageURL, href: href)
            }
        } catch {
            print("Error parsing AnimeSRBIJA: \(error.localizedDescription)")
            return []
        }
    }

    func parseAniWorld(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        var results: [(title: String, imageUrl: String, href: String)] = []
        let searchQuery = query.lowercased()

        do {
            let genreElements = try document.select("div.genre")
            for genreElement in genreElements {
                let anchorElements = try genreElement.select("a")

                for anchor in anchorElements {
                    let title = try anchor.text()
                    let href = try anchor.attr("href")
                    if title.lowercased().contains(searchQuery) {
                        results.append((
                            title: title,
                            imageUrl: "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg",
                            href: "https://aniworld.to\(href)"
                        ))
                    }
                }
            }
        } catch {
            print("Error parsing AniWorld HTML: \(error.localizedDescription)")
        }
        let sortedResults = results.sorted { $0.title.lowercased() < $1.title.lowercased() }
        return sortedResults
    }

    func parseTokyoInsider(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div#inner_page table[cellpadding='3'] tr")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("a").attr("title")

                var imageUrl = try item.select("img").attr("src")
                imageUrl = imageUrl.replacingOccurrences(of: "small", with: "default")

                let href = try item.select("a").first()?.attr("href") ?? ""
                let hrefFull = "https://www.tokyoinsider.com" + href
                return (title: title, imageUrl: imageUrl, href: hrefFull)
            }
        } catch {
            print("Error parsing TokyoInsider: \(error.localizedDescription)")
            return []
        }
    }

    func parseAniVibe(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.listupd article")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("div.tt span").text()

                let imageUrl = try item.select("img").attr("src")

                let href = try item.select("a").first()?.attr("href") ?? ""
                let hrefFull = "https://anivibe.net" + href
                return (title: title, imageUrl: imageUrl, href: hrefFull)
            }
        } catch {
            print("Error parsing AniVibe: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeUnity(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        let baseURL = "https://www.animeunity.to/anime/"

        do {
            let rawHtml = try document.html()

            if let startIndex = rawHtml.range(of: "<archivio")?.upperBound,
               let endIndex = rawHtml.range(of: "</archivio>")?.lowerBound {

                let archivioContent = String(rawHtml[startIndex..<endIndex])

                if let recordsStart = archivioContent.range(of: "records=\"")?.upperBound,
                   let recordsEnd = archivioContent[recordsStart...].range(of: "\"")?.lowerBound {

                    let recordsJson = String(archivioContent[recordsStart..<recordsEnd])
                        .replacingOccurrences(of: """, with: "\"")

                    if let recordsData = recordsJson.data(using: .utf8),
                       let recordsList = try? JSONSerialization.jsonObject(with: recordsData) as? [[String: Any]] {

                        return recordsList.compactMap { record in
                            guard let title = record["title"] as? String,
                                  let imageUrl = record["imageurl"] as? String,
                                  let animeID = record["id"] as? Int,
                                  let slug = record["slug"] as? String else {
                                return nil
                            }

                            let hrefFull = "\(baseURL)\(animeID)-\(slug)"
                            return (title: title, imageUrl: imageUrl, href: hrefFull)
                        }
                    }
                }
            }

            print("Could not find or parse <archivio> element")
            return []
        } catch {
            print("Error parsing AnimeUnity: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeFLV(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("ul.ListAnimes li")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("h3.Title").text()

                let imageUrl = try item.select("img").attr("src")

                let href = try item.select("a").first()?.attr("href") ?? ""
                let hrefFull = "https://www3.animeflv.net" + href
                return (title: title, imageUrl: imageUrl, href: hrefFull)
            }
        } catch {
            print("Error parsing AnimeFLV: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeBalkan(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("article.bs")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("h2").text()

                let imageUrl = try item.select("img").attr("data-src")

                let href = try item.select("a").first()?.attr("href") ?? ""
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeBalkan: \(error.localizedDescription)")
            return []
        }
    }

    func parseAniBunker(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.section--body article")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("h4").text()

                let imageUrl = try item.select("img").attr("src")

                let href = try item.select("a").first()?.attr("href") ?? ""
                let hrefFull = "https://www.anibunker.com/" + href

                return (title: title, imageUrl: imageUrl, href: hrefFull)
            }
        } catch {
            print("Error parsing AniBunker: \(error.localizedDescription)")
            return []
        }
    }
}
