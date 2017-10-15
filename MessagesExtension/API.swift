//
//  API.swift
//  Beets
//
//  Created by Aditya Sawhney on 10/3/16.
//  Copyright © 2016 Druid, LLC. All rights reserved.
//

import UIKit
import AFNetworking

/**
 Wrapper methods for interacting with the Beets server.
 
 - TODO:
     - Clean this up.
     - Add some kind of security to Beets server.
     - Add error handling.
 */
class API: NSObject {
    
    // Hardcoded because this is just for fun.
    let appURL = URL(string: "https://beets-145320.appspot.com")
    enum EndPoint: String {
        case Upload = "/upload"
    }
    enum ResponseKey: String {
        case UploadURL = "uploadURL"
        case AccessURL = "accessURL"
    }
    
    var uploadTask: URLSessionUploadTask?
    var downloadTask: URLSessionDownloadTask?
    
    /**
     Deletes a file stored locally. If an error is encountered, does nothing.
     
     - parameters:
         - url: The location of the file to delete.
     */
    private func deleteFile(atURL url: URL) {
        let fileManager = FileManager.default
        do { try fileManager.removeItem(at: url) }
        catch { }
    }
    
    /**
     Downloads a file stored at `remoteURL` to `localURL`, then invokes `completionHandler`.
     
     - parameters:
         - remoteURL: The URL to fetch from.
         - localURL: The URL to save to.
         - completionHandler: Invoked after attempted download. Parameter indicates success or failure.
     */
    func downloadItem(atURL remoteURL: URL, toFile localURL: URL, completionHandler: @escaping (Bool) -> Void) {
        let manager = AFURLSessionManager(sessionConfiguration: .default)
        let request = URLRequest(url: remoteURL)
        deleteFile(atURL: localURL)
        downloadTask = manager.downloadTask(with: request, progress: nil, destination: {(url, response) in return localURL }) { (response, url, error) in
            if let error = error {
                print(error)
                completionHandler(false)
            } else {
                completionHandler(true)
            }
        }
        downloadTask?.resume()
    }
    
    /**
     Uploads an item to Beets server using the given name, then calls `completionHandler`.
     
     - parameters:
         - url: The URL of the local file.
         - name: The name to use for the file.
         - completionHandler: Called upon termination, parameter is `nil` on failure or a String URL to access the uploaded item on success.
     */
    func uploadItem(atURL url: URL, withName name: String, andCompletion completionHandler: @escaping (String?) -> Void) {
        let reqEndpoint = EndPoint.Upload.rawValue
        guard let requestURL = NSURL(string: reqEndpoint, relativeTo: appURL) else { return }
        
        let sessionManager = AFHTTPSessionManager(sessionConfiguration: .default)
        
        let request = sessionManager.requestSerializer.multipartFormRequest(withMethod: "PUT", urlString: "http://localhost:3000/upload", parameters: ["uploadType" : "multipart", "name": "upl"], constructingBodyWith: { (formData) in
            do { try formData.appendPart(withFileURL: url, name: "upl", fileName: name, mimeType: "audio/x-caf") }
            catch { print("Error appending part") }
            }, error: nil)
        
        let contentType = request.allHTTPHeaderFields?["Content-Type"]
        let pieces = contentType?.characters.split(separator: ";").map(String.init)
        let boundary = pieces![1]
        
        let contentheader = "multipart/related;\(boundary)"
        
        request.setValue(contentheader, forHTTPHeaderField: "Content-Type")
        //            request.setValue("\(contentSize)", forHTTPHeaderField: "Content-Length")
        
        let param = [
            "fieldName" : "upl",
            "uniqueID"   : name,
            "contentType": contentheader
        ]
        
        let progressHandler = { (progress: Progress) in
            print("getURLsProgress: \(progress.fractionCompleted)")
        }
        
        sessionManager.get(requestURL.absoluteString!, parameters: param, progress: progressHandler, success: { (dataTask, data) in
            if let data = data as? [String: AnyObject] {
                guard let accessURLString = data[ResponseKey.AccessURL.rawValue] as? String else {
                    return
                }
                
                if let uploadURL = data[ResponseKey.UploadURL.rawValue] as? String {
                    request.url = URL(string: uploadURL)
                    sessionManager.responseSerializer = AFHTTPResponseSerializer()
                    self.uploadTask = sessionManager.uploadTask(with: request as URLRequest, fromFile: url, progress: nil) { (response, data, error) in
                        if error != nil {
                            completionHandler(nil)
                            return
                        }
                        
                        completionHandler(accessURLString)
                    }
                    self.uploadTask?.resume()
                }
            }
            }, failure: { (dataTask, error) in
                print(error)
                completionHandler(nil)
        })
    }
    
}
