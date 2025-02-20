//
//  ToplistsStore.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/08.
//

import ComposableArchitecture

struct ToplistsState: Equatable {
    enum Route: Equatable {
        case detail(String)
    }
    struct CancelID: Hashable {
        let id = String(describing: ToplistsState.self)
    }

    init() {
        _detailState = .init(.init())
    }

    @BindableState var route: Route?
    @BindableState var keyword = ""
    @BindableState var jumpPageIndex = ""
    @BindableState var jumpPageAlertFocused = false
    @BindableState var jumpPageAlertPresented = false

    var type: ToplistsType = .yesterday

    var filteredGalleries: [Gallery]? {
        guard !keyword.isEmpty else { return galleries }
        return galleries?.filter({ $0.title.caseInsensitiveContains(keyword) })
    }

    var rawGalleries = [ToplistsType: [Gallery]]()
    var rawPageNumber = [ToplistsType: PageNumber]()
    var rawLoadingState = [ToplistsType: LoadingState]()
    var rawFooterLoadingState = [ToplistsType: LoadingState]()

    var galleries: [Gallery]? {
        rawGalleries[type]
    }
    var pageNumber: PageNumber? {
        rawPageNumber[type]
    }
    var loadingState: LoadingState? {
        rawLoadingState[type]
    }
    var footerLoadingState: LoadingState? {
        rawFooterLoadingState[type]
    }

    @Heap var detailState: DetailState!

    mutating func insertGalleries(type: ToplistsType, galleries: [Gallery]) {
        galleries.forEach { gallery in
            if rawGalleries[type]?.contains(gallery) == false {
                rawGalleries[type]?.append(gallery)
            }
        }
    }
}

enum ToplistsAction: BindableAction {
    case binding(BindingAction<ToplistsState>)
    case setNavigation(ToplistsState.Route?)
    case setToplistsType(ToplistsType)
    case clearSubStates

    case performJumpPage
    case presentJumpPageAlert
    case setJumpPageAlertFocused(Bool)

    case teardown
    case fetchGalleries(Int? = nil)
    case fetchGalleriesDone(ToplistsType, Result<(PageNumber, [Gallery]), AppError>)
    case fetchMoreGalleries
    case fetchMoreGalleriesDone(ToplistsType, Result<(PageNumber, [Gallery]), AppError>)

    case detail(DetailAction)
}

struct ToplistsEnvironment {
    let urlClient: URLClient
    let fileClient: FileClient
    let imageClient: ImageClient
    let deviceClient: DeviceClient
    let hapticClient: HapticClient
    let cookiesClient: CookiesClient
    let databaseClient: DatabaseClient
    let clipboardClient: ClipboardClient
    let appDelegateClient: AppDelegateClient
    let uiApplicationClient: UIApplicationClient
}

let toplistsReducer = Reducer<ToplistsState, ToplistsAction, ToplistsEnvironment>.combine(
    .init { state, action, environment in
        switch action {
        case .binding(\.$route):
            return state.route == nil ? .init(value: .clearSubStates) : .none

        case .binding(\.$jumpPageAlertPresented):
            if !state.jumpPageAlertPresented {
                state.jumpPageAlertFocused = false
            }
            return .none

        case .binding:
            return .none

        case .setNavigation(let route):
            state.route = route
            return route == nil ? .init(value: .clearSubStates) : .none

        case .setToplistsType(let type):
            state.type = type
            guard state.galleries?.isEmpty != false else { return .none }
            return .init(value: ToplistsAction.fetchGalleries())

        case .clearSubStates:
            state.detailState = .init()
            return .init(value: .detail(.teardown))

        case .performJumpPage:
            guard let index = Int(state.jumpPageIndex),
                  let pageNumber = state.pageNumber,
                  index > 0, index <= pageNumber.maximum + 1 else {
                return environment.hapticClient.generateNotificationFeedback(.error).fireAndForget()
            }
            return .init(value: .fetchGalleries(index - 1))

        case .presentJumpPageAlert:
            state.jumpPageAlertPresented = true
            return environment.hapticClient.generateFeedback(.light).fireAndForget()

        case .setJumpPageAlertFocused(let isFocused):
            state.jumpPageAlertFocused = isFocused
            return .none

        case .teardown:
            return .cancel(id: ToplistsState.CancelID())

        case .fetchGalleries(let pageNum):
            guard state.loadingState != .loading else { return .none }
            state.rawLoadingState[state.type] = .loading
            if state.pageNumber == nil {
                state.rawPageNumber[state.type] = PageNumber()
            } else {
                state.rawPageNumber[state.type]?.current = 0
            }
            return ToplistsGalleriesRequest(catIndex: state.type.categoryIndex, pageNum: pageNum)
                .effect.map({ [type = state.type] in ToplistsAction.fetchGalleriesDone(type, $0) })
                .cancellable(id: ToplistsState.CancelID())

        case .fetchGalleriesDone(let type, let result):
            state.rawLoadingState[type] = .idle
            switch result {
            case .success(let (pageNumber, galleries)):
                guard !galleries.isEmpty else {
                    state.rawLoadingState[type] = .failed(.notFound)
                    guard pageNumber.current < pageNumber.maximum else { return .none }
                    return .init(value: .fetchMoreGalleries)
                }
                state.rawPageNumber[type] = pageNumber
                state.rawGalleries[type] = galleries
                return environment.databaseClient.cacheGalleries(galleries).fireAndForget()
            case .failure(let error):
                state.rawLoadingState[type] = .failed(error)
            }
            return .none

        case .fetchMoreGalleries:
            let pageNumber = state.pageNumber ?? .init()
            guard pageNumber.current + 1 <= pageNumber.maximum,
                  state.footerLoadingState != .loading
            else { return .none }
            state.rawFooterLoadingState[state.type] = .loading
            let pageNum = pageNumber.current + 1
            let lastID = state.rawGalleries[state.type]?.last?.id ?? ""
            return MoreToplistsGalleriesRequest(catIndex: state.type.categoryIndex, pageNum: pageNum)
                .effect.map({ [type = state.type] in ToplistsAction.fetchMoreGalleriesDone(type, $0) })
                .cancellable(id: ToplistsState.CancelID())

        case .fetchMoreGalleriesDone(let type, let result):
            state.rawFooterLoadingState[type] = .idle
            switch result {
            case .success(let (pageNumber, galleries)):
                state.rawPageNumber[type] = pageNumber
                state.insertGalleries(type: type, galleries: galleries)

                var effects: [Effect<ToplistsAction, Never>] = [
                    environment.databaseClient.cacheGalleries(galleries).fireAndForget()
                ]
                if galleries.isEmpty, pageNumber.current < pageNumber.maximum {
                    effects.append(.init(value: .fetchMoreGalleries))
                } else if !galleries.isEmpty {
                    state.rawLoadingState[type] = .idle
                }
                return .merge(effects)

            case .failure(let error):
                state.rawFooterLoadingState[type] = .failed(error)
            }
            return .none

        case .detail:
            return .none
        }
    }
    .binding(),
    detailReducer.pullback(
        state: \.detailState,
        action: /ToplistsAction.detail,
        environment: {
            .init(
                urlClient: $0.urlClient,
                fileClient: $0.fileClient,
                imageClient: $0.imageClient,
                deviceClient: $0.deviceClient,
                hapticClient: $0.hapticClient,
                cookiesClient: $0.cookiesClient,
                databaseClient: $0.databaseClient,
                clipboardClient: $0.clipboardClient,
                appDelegateClient: $0.appDelegateClient,
                uiApplicationClient: $0.uiApplicationClient
            )
        }
    )
)
