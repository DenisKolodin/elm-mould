effect module Mould where { command = MyCmd, subscription = MySub } exposing
    ( Request
    , send
    , Response(..)
    , SubRequest
    , answer
    , cancel
    , suspend
    , resume
    , interact
    , Notification(..)
    , listen
    , FailReason(..)
    , failToString
    )

{-| Client library for connecting to a Mould server.

# Subscribtions
@docs listen, interact

# Messaging
@docs send, answer, cancel, suspend, resume, Request, SubRequest, Response, Notification, FailReason

# Utils
@docs failToString

-}

import Set exposing (Set)
import Dict exposing (Dict)
import Json.Encode as JS
import Json.Decode as JD exposing (field)
import Task exposing (Task)
import Process
import WebSocket.LowLevel as WS

type alias Tag = String
type alias Url = String

{-| Request to a Mould server.
-}
type alias Request =
    { service: String
    , action: String
    , payload: JS.Value
    }

{-| SubRequest for answering to a Mould server.
-}
type alias SubRequest = JS.Value

{-| Type with reason why task failed.
-}
type FailReason
    = UnknownEvent String
    | ParseError String
    | NoDataProvided
    | ConnectionBroken
    | UnexpectedAnswer String
    | UnexpectedSuspend String
    | UnexpectedCancel String
    | HasActiveTask String
    | InternalError String
    | Canceled

-- TODO IMPORTANT TO MOVE TAG OUT: (tag, Response)
{-| Response from Mould server.
-}
type Response
    = Done
    | Received JD.Value
    | Failed FailReason
    | Asking
    | Suspended Int

type MyCmd msg
    = Send Url Tag Request
    | Answer Url Tag (Maybe SubRequest)
    | Suspend Url Tag
    | Resume Url Tag Int
    | Cancel Url Tag

{-| Convert FailReason to user readable string.
-}
failToString : FailReason -> String
failToString fail =
    case fail of
        UnknownEvent event ->
            "unknown event " ++ event
        ParseError error ->
            "parse error " ++ error
        NoDataProvided ->
            "no data provided"
        ConnectionBroken ->
            "connection broken"
        UnexpectedAnswer tag ->
            "unexpected answer " ++ tag
        UnexpectedSuspend tag ->
            "unexpected suspend " ++ tag
        UnexpectedCancel tag ->
            "unexpected cancel " ++ tag
        HasActiveTask tag ->
            "has active task " ++ tag
        InternalError reason ->
            "internal error " ++ reason
        Canceled ->
            "task was cancelled"

-- Effect Module API
cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ cmd =
    case cmd of
        Send url tag request ->
            Send url tag request
        Answer url tag maybeSubRequest ->
            Answer url tag maybeSubRequest
        Suspend url tag ->
            Suspend url tag
        Resume url tag taskId ->
            Resume url tag taskId
        Cancel url tag ->
            Cancel url tag

getCmdTag : MyCmd a -> String
getCmdTag cmd =
    case cmd of
        Send _ tag _ -> tag
        Answer _ tag _ -> tag
        Suspend _ tag -> tag
        Resume _ tag _ -> tag
        Cancel _ tag -> tag

getCmdUrl : MyCmd a -> String
getCmdUrl cmd =
    case cmd of
        Send url _ _ -> url
        Answer url _ _ -> url
        Suspend url _ -> url
        Resume url _ _ -> url
        Cancel url _ -> url

{-| Send a new request to a mould session. Use it like this:

    request =
        { service = "auth-service"
        , action = "do-auth"
        , payload = JS.object
            [ ("login", JS.string login)
            , ("password", JS.string password)
            ]
        }

    Mould.send "ws://mould.example.com" "task-id" request
-}
send : Url -> Tag -> Request -> Cmd msg
send url tag request =
    command (Send url tag request)

{-| Send answer to a **ready** message. Use it like this:

    Mould.answer "ws://mould.example.com" "task-id" Nothing
-}
answer : Url -> Tag -> Maybe SubRequest -> Cmd msg
answer url tag maybeSubRequest =
    command (Answer url tag maybeSubRequest)

{-| Suspend current task with **id**. Suspended id response expected. Example:

    Mould.suspend "ws://mould.example.com" "task-id"
-}
suspend : Url -> Tag -> Cmd msg
suspend url tag =
    command (Suspend url tag)

{-| Resume current task with **id**. Task should be suspended before (task-id retrived). Example:

    Mould.resume "ws://mould.example.com" "task-id" 0
-}
resume : Url -> Tag -> Int -> Cmd msg
resume url tag taskId =
    command (Resume url tag taskId)

{-| Cancel current task with **id**. Example:

    Mould.cancel "ws://mould.example.com" "task-id"
-}
cancel : Url -> Tag -> Cmd msg
cancel url tag =
    command (Cancel url tag)

-- SUBSCRIPTIONS

type MySub msg
  = Interact Url Tag (Response -> msg)
  | Listen Url (Notification -> msg)

-- Effect Module API
subMap : (a -> b) -> MySub a -> MySub b
subMap func sub =
    case sub of
        Interact url tag wrapper ->
            Interact url tag (wrapper >> func)
        Listen url wrapper ->
            Listen url (wrapper >> func)

getSubUrl : MySub a -> Url
getSubUrl sub =
    case sub of
        Interact url _ _ -> url
        Listen url _ -> url

{-| Subscribe to interaction messages from mould server. Example:

    type Msg = MouldTag String | ...

    subscriptions model =
        Mould.interact "ws://mould.example.com" MouldTag
-}
interact : Url -> Tag -> (Response -> msg) -> Sub msg
interact url tag wrapper =
    subscription (Interact url tag wrapper)

{-| Subscribe to notification messages from this library. Example:

    type Msg = NotifyTag String | ...

    subscriptions model =
        Mould.listen "ws://mould.example.com" NotifyTag
-}
listen : Url -> (Notification -> msg) -> Sub msg
listen url wrapper =
    subscription (Listen url wrapper)

type TaskOrigin
    = FromRequest Request
    | FromId Int

type Task
    = Idle
    | Active String TaskOrigin

{-| It's an unique connection to a server.
-}
type alias Uplink msg = Dict Url (State msg)

type alias Interactors msg = Dict Tag (Response -> msg)

type alias State msg =
    { status : Status
    , task : Task
    , interactors : Interactors msg
    , listeners : List (Notification -> msg)
    }

type Status
    = Disconnected
    | Opening Process.Id
    | Connected WS.WebSocket

{-| Client status notifications subscribing by `listen`.
-}
type Notification
    = ConnectionEstablished
    | ConnectionLost
    | BeginTask String
    | EndTask String
    | UntrackedEvent String

-- Effect Module API
init : Platform.Task Never (Uplink msg)
init =
    Task.succeed Dict.empty

initState : State msg
initState =
    { status = Disconnected
    , task = Idle
    , interactors = Dict.empty
    , listeners = []
    }

-- HANDLE APP MESSAGES

-- Effect Module API
onEffects
    : Platform.Router msg Msg
    -> List (MyCmd msg)
    -> List (MySub msg)
    -> Uplink msg
    -> Platform.Task Never (Uplink msg)
onEffects router cmds subs uplink =
    let
        expectedUplink =
            subs
            |> List.map (\sub -> (getSubUrl sub, ()))
            |> Dict.fromList
        cmdFilter url = List.filter (\cmd -> getCmdUrl cmd == url) cmds
        subFilter url = List.filter (\sub -> getSubUrl sub == url) subs
        keepSub url _ state uplinkTask =
            uplinkTask
            |> Task.andThen (\uplink_ -> onEffectsState router url (cmdFilter url) (subFilter url) state
            |> Task.andThen (\state -> Task.succeed (Dict.insert url state uplink_)))
        newSub url blank uplinkTask =
            keepSub url blank initState uplinkTask
        leaveSub url state uplinkTask =
            close state.status
            |> Task.andThen (\_ -> uplinkTask)
    in
       Dict.merge newSub keepSub leaveSub expectedUplink uplink (Task.succeed uplink)

onEffectsState
    : Platform.Router msg Msg
    -> String
    -> List (MyCmd msg)
    -> List (MySub msg)
    -> State msg
    -> Platform.Task Never (State msg)
onEffectsState router url cmds subs state =
    Task.succeed state
    |> Task.andThen (\state1 -> connectIfDisconnected router url state1)
    |> Task.andThen (\state2 -> processSubscriptions router subs state2)
    |> Task.andThen (\state3 -> processCommands router cmds state3)

connectIfDisconnected : Platform.Router msg Msg -> String -> State msg -> Platform.Task Never (State msg)
connectIfDisconnected router url state =
    case state.status of
        Disconnected ->
            open url router
            |> Task.andThen (\pid -> Task.succeed { state | status = Opening pid })
        _ ->
            Task.succeed state

processSubscriptions
    : Platform.Router msg Msg
    -> List (MySub msg)
    -> State msg
    -> Platform.Task Never (State msg)
processSubscriptions router subs state =
    let
        listenerExtractor sub = case sub of
            Listen _ wrapper -> Just wrapper
            _ -> Nothing
        interactorExtractor sub = case sub of
            Interact _ tag wrapper -> Just (tag, wrapper)
            _ -> Nothing
        -- TODO But important to reject tasks of removed subscriptions and send notification about it
        listeners_ = List.filterMap listenerExtractor subs
        interactors_ = List.filterMap interactorExtractor subs
    in
        Task.succeed { state | interactors = Dict.fromList interactors_, listeners = listeners_ }

processCommands
    : Platform.Router msg Msg
    -> List (MyCmd msg)
    -> State msg
    -> Platform.Task Never (State msg)
processCommands router cmds state =
    let
        notifyInteractor tag msg =
            notifyDirect router state.interactors tag msg
        notifyListeners msg =
            notifyAll router state.listeners msg
    in case (cmds, state.task, state.status) of
        -- NO TASKS
        ([], _, _) ->
            Task.succeed state
        -- SEND NEW | NO ACTIVE | CONNECTED
        ((Send url tag request) :: tail, Idle, Connected socket) ->
            WS.send socket (stringifyRequest request)
            |> Task.andThen
                (\maybeBadSend -> case maybeBadSend of
                    Just badSend ->
                        notifyInteractor tag (Failed ConnectionBroken)
                        |> Task.andThen (\_ -> Task.succeed state) -- stay Idle
                    Nothing ->
                        notifyListeners (BeginTask tag)
                        |> Task.andThen (\_ -> Task.succeed { state | task = Active tag <| FromRequest request })
                    |> Task.andThen (\state -> processCommands router tail state)
                )
        -- RESUME INTERACTION | NO ACTIVE | CONNECTED
        ((Resume url tag taskId) :: tail, Idle, Connected socket) -> WS.send socket (stringifyResume taskId)
            |> Task.andThen
                (\maybeBadSend -> case maybeBadSend of
                    Just badSend ->
                        notifyInteractor tag (Failed ConnectionBroken)
                        |> Task.andThen (\_ -> Task.succeed state) -- stay Idle
                    Nothing ->
                        notifyListeners (BeginTask tag)
                        |> Task.andThen (\_ -> Task.succeed { state | task = Active tag <| FromId taskId })
                    |> Task.andThen (\state -> processCommands router tail state)
                )
        -- ANSWER CURRENT | HAS ACTIVE | CONNECTED
        ((Answer url tag maybeSubRequest) :: tail, Active activeTag _, Connected socket) ->
            if tag /= activeTag then
                notifyInteractor tag (Failed (UnexpectedAnswer activeTag))
                |> Task.andThen (\_ -> processCommands router tail state)
            else
                WS.send socket (stringifyNext maybeSubRequest)
                |> Task.andThen
                    (\maybeBadSend -> case maybeBadSend of
                        Just badSend ->
                            notifyInteractor tag (Failed ConnectionBroken)
                            |> Task.andThen (\_ -> Task.succeed { state | task = Idle }) -- become Idle
                        Nothing ->
                            Task.succeed state -- stay Active
                        |> Task.andThen (\state -> processCommands router tail state)
                    )
        -- SUSPEND CURRENT | HAS ACTIVE | CONNECTED
        ((Suspend url tag) :: tail, Active activeTag _, Connected socket) ->
            if tag /= activeTag then
                notifyInteractor tag (Failed (UnexpectedSuspend activeTag))
                |> Task.andThen (\_ -> processCommands router tail state)
            else
                WS.send socket (stringifySuspend)
                |> Task.andThen
                    (\maybeBadSend -> case maybeBadSend of
                        Just badSend ->
                            notifyInteractor tag (Failed ConnectionBroken)
                            |> Task.andThen (\_ -> Task.succeed { state | task = Idle }) -- become Idle
                        Nothing ->
                            Task.succeed state -- stay Active
                        |> Task.andThen (\state -> processCommands router tail state)
                    )
        -- CANCEL CURRENT | HAS ACTIVE | CONNECTED
        ((Cancel url tag) :: tail, Active activeTag _, Connected socket) ->
            if tag /= activeTag then
                notifyInteractor tag (Failed (UnexpectedCancel activeTag))
                |> Task.andThen (\_ -> processCommands router tail state)
            else
                WS.send socket (stringifyCancel)
                |> Task.andThen
                    (\maybeBadSend ->
                    let
                        failedMsg = case maybeBadSend of
                            Just badSend -> (Failed ConnectionBroken)
                            Nothing -> (Failed Canceled)
                    in
                        notifyListeners (EndTask tag)
                        |> Task.andThen (\_ -> notifyInteractor tag failedMsg)
                        |> Task.andThen (\_ -> Task.succeed { state | task = Idle }) -- become Idle
                        |> Task.andThen (\state -> processCommands router tail state)
                    )
        -- SEND NEW | HAS ACTIVE | ANY
        ((Send url tag _) :: tail, Active activeTag _, _) ->
            notifyInteractor tag (Failed (HasActiveTask activeTag))
            |> Task.andThen (\_ -> processCommands router tail state)
        -- ANY | ANY | ANY
        (cmd :: tail, _, _) ->
            notifyInteractor (getCmdTag cmd) (Failed ConnectionBroken)
            |> Task.andThen (\_ -> processCommands router tail state)

-- HANDLE SELF MESSAGES

type Msg
    = Receive String String
    | Die String
    | GoodOpen String WS.WebSocket
    | BadOpen String

getMsgUrl : Msg -> String
getMsgUrl msg =
    case msg of
        Receive url _ -> url
        Die url -> url
        GoodOpen url _ -> url
        BadOpen url -> url

-- Effect Module API
onSelfMsg
    : Platform.Router msg Msg
    -> Msg
    -> Uplink msg
    -> Platform.Task Never (Uplink msg)
onSelfMsg router selfMsg uplink =
    let
        url = getMsgUrl selfMsg
    in
        case Dict.get url uplink of
            Just state ->
                onSelfMsgState router selfMsg state
                |> Task.andThen (\state_ -> Task.succeed (Dict.insert url state_ uplink))
            Nothing ->
                Task.succeed uplink

onSelfMsgState
    : Platform.Router msg Msg
    -> Msg
    -> State msg
    -> Platform.Task Never (State msg)
onSelfMsgState router selfMsg state =
    let
        notifyInteractor tag msg =
            notifyDirect router state.interactors tag msg
        notifyListeners msg =
            notifyAll router state.listeners msg
    in case selfMsg of
        Receive url data -> case state.task of
            Active tag _ ->
                let
                    response =
                        parseToResponse tag data
                    readyToNext =
                        case response of
                            Done -> True
                            Failed _ -> True
                            Suspended _ -> True
                            Received _ -> False
                            Asking -> False
                in
                    notifyInteractor tag response
                    |> Task.andThen
                        (\_ ->
                        if readyToNext then
                            notifyListeners (EndTask tag)
                            |> Task.andThen (\_ -> Task.succeed { state | task = Idle })
                        else
                            Task.succeed state
                        )
            Idle ->
                notifyListeners (UntrackedEvent data)
                |> Task.andThen (\_ -> Task.succeed state)
        GoodOpen url socket ->
            notifyListeners ConnectionEstablished
            |> Task.andThen (\_ -> Task.succeed { state | status = Connected socket })
        BadOpen url ->
            open url router
            |> Task.andThen (\pid -> Task.succeed { state | status = Opening pid })
        Die url ->
            notifyListeners ConnectionLost
            |> Task.andThen (\_ -> open url router)
            |> Task.andThen (\pid -> Task.succeed { state | status = Opening pid })
            |> Task.andThen
                (\state_ -> case state.task of
                    Idle ->
                        Task.succeed state_
                    Active tag _ ->
                        notifyInteractor tag (Failed ConnectionBroken)
                        |> Task.andThen (\_ -> Task.succeed { state_ | task = Idle })
                )

open : String -> Platform.Router msg Msg -> Platform.Task Never Process.Id
open url router =
    let
        goodOpen ws =
            Platform.sendToSelf router (GoodOpen url ws)
        badOpen details =
            Platform.sendToSelf router (BadOpen url)
        receive ws msg =
            Platform.sendToSelf router (Receive url msg)
        die details =
            Platform.sendToSelf router (Die url)
        settings =
            { onMessage = receive
            , onClose = die
            }
    in
        WS.open url settings
        |> Task.andThen goodOpen
        |> Task.onError badOpen
        |> Process.spawn

close : Status -> Platform.Task x ()
close status =
    case status of
        Opening pid ->
            Process.kill pid
        Connected socket ->
            WS.close socket
        Disconnected ->
            Task.succeed ()

parseToResponse : String -> String -> Response
parseToResponse tag data =
    case decodeEvent data of
        Ok event ->
            case event.event of
                "ready" ->
                    Asking
                "item" ->
                    case event.data of
                        Just data ->
                            Received data
                        Nothing ->
                            Failed NoDataProvided
                "done" ->
                    Done
                "fail" ->
                    case event.data of
                        Just data ->
                            case (JD.decodeValue JD.string data) of
                                Ok reason ->
                                    Failed (InternalError reason)
                                Err explanation ->
                                    Failed (ParseError explanation)
                        Nothing ->
                            Failed NoDataProvided
                "suspended" ->
                    case event.data of
                        Just data ->
                            case (JD.decodeValue JD.int data) of
                                Ok taskId ->
                                    Suspended taskId
                                Err explanation ->
                                    Failed (ParseError explanation)
                        Nothing ->
                            Failed NoDataProvided
                unknown ->
                    Failed (UnknownEvent unknown)
        Err explanation ->
            Failed (ParseError explanation)

notifyAll : Platform.Router msg Msg -> List (Notification -> msg) -> Notification -> Platform.Task x (List ())
notifyAll router taggers msgObj =
    let
        sends =
            List.map (\wrapper -> Platform.sendToApp router (wrapper msgObj)) taggers
    in
       Task.sequence sends

notifyDirect : Platform.Router msg Msg -> Interactors msg -> Tag -> Response -> Platform.Task x ()
notifyDirect router taggers tag msgObj =
    case Dict.get tag taggers of
        Just wrapper -> Platform.sendToApp router (wrapper msgObj)
        Nothing -> Task.succeed () -- TODO Log about fatal error

-- INTERNALS
type alias Event =
    { event: String
    , data: Maybe JS.Value
    }

eventDecoder : JD.Decoder Event
eventDecoder =
    JD.map2 Event
        (field "event" JD.string)
        (JD.maybe <| field "data" JD.value)


decodeEvent : String -> (Result String Event)
decodeEvent json =
    JD.decodeString eventDecoder json

stringifyRequest : Request -> String
stringifyRequest request =
    let
        data = JS.object
            [ ("service", JS.string request.service)
            , ("action", JS.string request.action)
            , ("payload", request.payload)
            ]
    in
        JS.encode 0 (createEvent "request" (Just data))

stringifyNext : Maybe SubRequest -> String
stringifyNext maybeSubReuqest =
    JS.encode 0 (createEvent "next" maybeSubReuqest)

stringifySuspend : String
stringifySuspend =
    JS.encode 0 (createEvent "suspend" Nothing)

stringifyResume : Int -> String
stringifyResume taskId =
    let
        data = JS.int taskId
    in
        JS.encode 0 (createEvent "resume" (Just data))

stringifyCancel : String
stringifyCancel =
    JS.encode 0 (createEvent "cancel" Nothing)

createEvent : String -> Maybe JS.Value -> JS.Value
createEvent name data =
    case data of
        Just data ->
            JS.object
                [ ("event", JS.string name)
                , ("data", data)
                ]
        Nothing ->
            JS.object
                [ ("event", JS.string name)
                , ("data", JS.null)
                ]
