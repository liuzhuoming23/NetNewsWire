//
//  CloudKitArticlesZone.swift
//  Account
//
//  Created by Maurice Parker on 4/1/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os.log
import RSParser
import RSWeb
import CloudKit
import Articles
import SyncDatabase

final class CloudKitArticlesZone: CloudKitZone {
	
	static var zoneID: CKRecordZone.ID {
		return CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
	}
	
	var log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")
	
	weak var container: CKContainer?
	weak var database: CKDatabase?
	var delegate: CloudKitZoneDelegate? = nil
	
	struct CloudKitArticle {
		static let recordType = "Article"
		struct Fields {
			static let articleStatus = "articleStatus"
			static let webFeedURL = "webFeedURL"
			static let uniqueID = "uniqueID"
			static let title = "title"
			static let contentHTML = "contentHTML"
			static let contentText = "contentText"
			static let url = "url"
			static let externalURL = "externalURL"
			static let summary = "summary"
			static let imageURL = "imageURL"
			static let datePublished = "datePublished"
			static let dateModified = "dateModified"
			static let parsedAuthors = "parsedAuthors"
		}
	}

	struct CloudKitArticleStatus {
		static let recordType = "ArticleStatus"
		struct Fields {
			static let webFeedExternalID = "webFeedExternalID"
			static let read = "read"
			static let starred = "starred"
		}
	}

	init(container: CKContainer) {
		self.container = container
		self.database = container.privateCloudDatabase
	}
	
	func refreshArticles(completion: @escaping ((Result<Void, Error>) -> Void)) {
		fetchChangesInZone() { result in
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				if case CloudKitZoneError.userDeletedZone = error {
					self.createZoneRecord() { result in
						switch result {
						case .success:
							self.refreshArticles(completion: completion)
						case .failure(let error):
							completion(.failure(error))
						}
					}
				} else {
					completion(.failure(error))
				}
			}
		}
	}
	
	func saveNewArticles(_ articles: Set<Article>, completion: @escaping ((Result<Void, Error>) -> Void)) {
		guard !articles.isEmpty else {
			completion(.success(()))
			return
		}
		
		var records = [CKRecord]()
		
		let saveArticles = articles.filter { $0.status.read == false || $0.status.starred == true }
		for saveArticle in saveArticles {
			records.append(contentsOf: makeArticleRecords(saveArticle))
		}

		saveIfNew(records, completion: completion)
	}
	
	func deleteArticles(_ webFeedExternalID: String, completion: @escaping ((Result<Void, Error>) -> Void)) {
		let predicate = NSPredicate(format: "webFeedExternalID = %@", webFeedExternalID)
		let ckQuery = CKQuery(recordType: CloudKitArticleStatus.recordType, predicate: predicate)
		delete(ckQuery: ckQuery, completion: completion)
	}
	
	func modifyArticles(_ statusArticles: [(status: SyncStatus, article: Article?)], completion: @escaping ((Result<Void, Error>) -> Void)) {
		guard !statusArticles.isEmpty else {
			completion(.success(()))
			return
		}
		
		var newRecords = [CKRecord]()
		var modifyRecords = [CKRecord]()
		var deleteRecordIDs = [CKRecord.ID]()
		
		for statusArticle in statusArticles {
			switch (statusArticle.status.key, statusArticle.status.flag) {
			case (.new, true):
				newRecords.append(makeStatusRecord(statusArticle))
				if let article = statusArticle.article {
					newRecords.append(contentsOf: makeArticleRecords(article))
				}
			case (.starred, true), (.read, false):
				modifyRecords.append(makeStatusRecord(statusArticle))
				if let article = statusArticle.article {
					modifyRecords.append(contentsOf: makeArticleRecords(article))
				}
			case (.deleted, true):
				deleteRecordIDs.append(CKRecord.ID(recordName: statusID(statusArticle.status.articleID), zoneID: Self.zoneID))
			default:
				modifyRecords.append(makeStatusRecord(statusArticle))
				deleteRecordIDs.append(CKRecord.ID(recordName: statusID(statusArticle.status.articleID), zoneID: Self.zoneID))
			}
		}
		
		saveIfNew(newRecords) { result in
			if case .failure(let error) = result, case CloudKitZoneError.userDeletedZone = error {
				self.createZoneRecord() { result in
					switch result {
					case .success:
						self.modifyArticles(statusArticles, completion: completion)
					case .failure(let error):
						completion(.failure(error))
					}
				}
			} else {
				self.modify(recordsToSave: modifyRecords, recordIDsToDelete: deleteRecordIDs) { result in
					switch result {
					case .success:
						completion(.success(()))
					case .failure(let error):
						completion(.failure(error))
					}
				}
			}
		}
	}
	
}

private extension CloudKitArticlesZone {
		
	func statusID(_ id: String) -> String {
		return "s|\(id)"
	}
	
	func articleID(_ id: String) -> String {
		return "a|\(id)"
	}
	
	func makeStatusRecord(_ statusArticle: (status: SyncStatus, article: Article?)) -> CKRecord {
		let status = statusArticle.status
		let recordID = CKRecord.ID(recordName: statusID(status.articleID), zoneID: Self.zoneID)
		let record = CKRecord(recordType: CloudKitArticleStatus.recordType, recordID: recordID)
		
		if let webFeedExternalID = statusArticle.article?.webFeed?.externalID {
			record[CloudKitArticleStatus.Fields.webFeedExternalID] = webFeedExternalID
		}
		
		if let article = statusArticle.article {
			record[CloudKitArticleStatus.Fields.read] = article.status.read ? "1" : "0"
			record[CloudKitArticleStatus.Fields.starred] = article.status.starred ? "1" : "0"
		} else {
			switch status.key {
			case .read:
				record[CloudKitArticleStatus.Fields.read] = status.flag ? "1" : "0"
			case .starred:
				record[CloudKitArticleStatus.Fields.starred] = status.flag ? "1" : "0"
			default:
				break
			}
		}
		
		return record
	}
	
	func makeArticleRecords(_ article: Article) -> [CKRecord] {
		var records = [CKRecord]()

		let recordID = CKRecord.ID(recordName: articleID(article.articleID), zoneID: Self.zoneID)
		let articleRecord = CKRecord(recordType: CloudKitArticle.recordType, recordID: recordID)

		let articleStatusRecordID = CKRecord.ID(recordName: statusID(article.articleID), zoneID: Self.zoneID)
		articleRecord[CloudKitArticle.Fields.articleStatus] = CKRecord.Reference(recordID: articleStatusRecordID, action: .deleteSelf)
		articleRecord[CloudKitArticle.Fields.webFeedURL] = article.webFeed?.url
		articleRecord[CloudKitArticle.Fields.uniqueID] = article.uniqueID
		articleRecord[CloudKitArticle.Fields.title] = article.title
		articleRecord[CloudKitArticle.Fields.contentHTML] = article.contentHTML
		articleRecord[CloudKitArticle.Fields.contentText] = article.contentText
		articleRecord[CloudKitArticle.Fields.url] = article.url
		articleRecord[CloudKitArticle.Fields.externalURL] = article.externalURL
		articleRecord[CloudKitArticle.Fields.summary] = article.summary
		articleRecord[CloudKitArticle.Fields.imageURL] = article.imageURL
		articleRecord[CloudKitArticle.Fields.datePublished] = article.datePublished
		articleRecord[CloudKitArticle.Fields.dateModified] = article.dateModified
		
		let encoder = JSONEncoder()
		var parsedAuthors = [String]()
		
		if let authors = article.authors, !authors.isEmpty {
			for author in authors {
				let parsedAuthor = ParsedAuthor(name: author.name,
												url: author.url,
												avatarURL: author.avatarURL,
												emailAddress: author.emailAddress)
				if let data = try? encoder.encode(parsedAuthor), let encodedParsedAuthor = String(data: data, encoding: .utf8) {
					parsedAuthors.append(encodedParsedAuthor)
				}
			}
			articleRecord[CloudKitArticle.Fields.parsedAuthors] = parsedAuthors
		}
		
		records.append(articleRecord)
		return records
	}


}