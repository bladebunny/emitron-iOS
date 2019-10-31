/// Copyright (c) 2019 Razeware LLC
/// 
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
/// 
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
/// 
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
/// 
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import AuthenticationServices
import Foundation
import SwiftUI
import Combine
import Network

// Conforming to NSObject, so that we can conform to ASWebAuthenticationPresentationContextProviding
class UserMC: NSObject, ObservableObject, Refreshable {
  
  // MARK: Refreshable
  var refreshableUserDefaultsKey: String = "UserDefaultsRefreshable\(String(describing: UserMC.self))"
  var refreshableCheckTimeSpan: RefreshableTimeSpan = .short
  
  /// `Publisher` required by `BindableObject` protocol. This publisher gets sent a new `Void` value anytime `appState` changes.
  private(set) var objectWillChange = PassthroughSubject<Void, Never>()
  
  /// This is the app's entire state. The SwiftUI view hierarchy is a function of this state.
  private(set) var state = DataState.initial {
    willSet {
      objectWillChange.send(())
    }
  }
  
  private(set) var client: RWAPI
  private let guardpost: Guardpost
  private(set) var user: UserModel? {
    didSet {
      self.client = RWAPI(authToken: self.user?.token ?? "")
      self.permissionsService = PermissionsService(client: self.client)
    }
  }
  private(set) var permissionsService: PermissionsService
  private let connectionMonitor = NWPathMonitor()
  
  // MARK: - Initializers
  init(guardpost: Guardpost) {
    self.guardpost = guardpost
    self.user = guardpost.currentUser
    self.client = RWAPI(authToken: self.user?.token ?? "")
    self.permissionsService = PermissionsService(client: self.client)
    super.init()
		
    let queue = DispatchQueue(label: "Monitor")
    connectionMonitor.start(queue: queue)
  }
  
  // MARK: - Internal
  func login() {
    state = .loading
    guardpost.presentationContextDelegate = self
    
    if user != nil {
      if user?.permissions == nil {
        fetchPermissions()
      } else {
        state = .hasData
      }
    } else {
      guardpost.login { [weak self] result in
        
        guard let self = self else {
          return
        }
        
        switch result {
        case .failure(let error):
          self.state = .failed
          Failure
            .login(from: "UserMC", reason: error.localizedDescription)
            .log(additionalParams: nil)
        case .success(let user):
          self.user = user
          
          Event
            .login(from: "UserMC")
            .log(additionalParams: nil)

          self.fetchPermissions()
          
        }
      }
    }
  }
  
  func fetchPermissionsIfNeeded() {
    // Request persmission if an app launch has happened or if it's been oveer 24 hours since the last permission request once the app enters the foreground
    guard shouldRefresh else { return }
    
    fetchPermissions()
  }
  
  private func fetchPermissions() {
    // If there's no connection, use the persisted permissions
    // The re-fetch/re-store will be done the next time they open the app
    guard connectionMonitor.currentPath.status == .satisfied else { return }
    
    permissionsService.permissions { result in
      switch result {
      case .failure(let error):
        Failure
        .fetch(from: "UserMC_Permissions", reason: error.localizedDescription)
        .log(additionalParams: nil)
        
        self.state = .failed
      case .success(let permissions):
        self.user?.permissions = permissions
        
        // Update user to keychain
        if let user = self.user {
          PersistenceStore.current.persistUserToKeychain(user: user)
          self.saveOrReplaceRefreshableUpdateDate()
        }
        
        // If the user loses permissions to download videos (aka, they're not pro anymore), delete videos
        self.removeDownloadedContentIfNecessary()
        self.guardpost.updateUser(with: self.user)
        self.state = .hasData
      }
    }
  }
  
  func logout() {
    guardpost.logout()
    user = nil
    removeDownloadedContentIfNecessary()
    let appDelegate = UIApplication.shared.delegate as! AppDelegate
    appDelegate.dataManager = nil
    UserDefaults.standard.deleteAllFilters()
    // TODO: Should all the stores user defaults be removed at this point, aka the Settings?
    objectWillChange.send(())
  }
  
  // If the user is nil, or if they don't have download permissions, delete all downloaded content
  private func removeDownloadedContentIfNecessary() {
    guard let user = user else {
      DocumentManager.deleteAllDownloadedContent()
      return
    }
    
    if !user.canDownload {
      DocumentManager.deleteAllDownloadedContent()
    }
  }
}

// MARK: - ASWebAuthenticationPresentationContextProviding
extension UserMC: ASWebAuthenticationPresentationContextProviding {
  
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    return UIApplication.shared.windows.first!
  }
}
