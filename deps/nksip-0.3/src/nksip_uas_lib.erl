%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc UAS Process helper functions
-module(nksip_uas_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([preprocess/1, make/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Preprocess an incoming request.
%% Returns `own_ack' if the request is an ACK to a [3456]xx response generated by
%% NkSip, or the preprocessed request in any other case. 
%%
%% If performs the following actions:
%% <ul>
%%  <li>Adds rport, received and transport options to Via.</li>
%%  <li>Generates a To Tag candidate.</li>
%%  <li>Performs strict routing processing.</li>
%%  <li>Updates the request if maddr is present.</li>
%%  <li>Removes first route if it is poiting to us.</li>
%% </ul>
%%

-spec preprocess(nksip:request()) ->
    nksip:request() | own_ack.

preprocess(Req) ->
    #sipmsg{
        class = {req, Method},
        to = {_, ToTag},
        transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port}, 
        vias = [Via|ViaR]
    } = Req,
    Received = nksip_lib:to_host(Ip, false), 
    ViaOpts1 = [{<<"received">>, Received}|Via#via.opts],
    % For UDP, we honor de rport option
    % For connection transports, we force inclusion of remote port 
    % to reuse the same connection
    ViaOpts2 = case lists:member(<<"rport">>, ViaOpts1) of
        false when Proto==udp -> ViaOpts1;
        _ -> [{<<"rport">>, nksip_lib:to_binary(Port)} | ViaOpts1 -- [<<"rport">>]]
    end,
    Via1 = Via#via{opts=ViaOpts2},
    Branch = nksip_lib:get_binary(<<"branch">>, ViaOpts2),
    GlobalId = nksip_config_cache:global_id(),
    ToTag1 = case ToTag of
        <<>> -> nksip_lib:hash({GlobalId, Branch});
        _ -> ToTag
    end,
    case Method=='ACK' andalso nksip_lib:hash({GlobalId, Branch})==ToTag of
        true -> 
            ?call_debug("Received ACK for own-generated response", []),
            own_ack;
        false ->
            Req1 = Req#sipmsg{
                vias = [Via1|ViaR], 
                to_tag_candidate = ToTag1
            },
            Req2 = strict_router(Req1),
            ruri_has_maddr(Req2)
    end.



%% @private
-spec make(nksip:request(), nksip:response_code(), nksip_lib:optslist()) -> 
    {ok, nksip:response(), nksip_lib:optslist()} | {error, term()}.

make(Req, Code, Opts) ->
  #sipmsg{
        app_id = AppId,
        class = {req, Method},
        ruri = RUri,
        vias = [LastVia|_] = Vias,
        cseq = {CSeqNum, _},
        to = {#uri{ext_opts=ExtOpts}=To, ToTag},
        routes = Routes,
        contacts = Contacts,
        require = Require,
        to_tag_candidate = NewToTag
    } = Req, 
    NewToTag1 = case NewToTag of
        <<>> -> nksip_lib:hash(make_ref());
        _ -> NewToTag
    end,
    case Code of
        100 -> 
            Vias1 = [LastVia],
            ExtOpts1 = lists:keydelete(<<"tag">>, 1, ExtOpts),
            {To1, ToTag1} = {To#uri{ext_opts=ExtOpts1}, <<>>};
        _ -> 
            Vias1 = Vias,
            {To1, ToTag1} = case ToTag of
                <<>> -> 
                    ExtOpts1 = [{<<"tag">>, NewToTag1}|ExtOpts],
                    {To#uri{ext_opts=ExtOpts1}, NewToTag1};
                _ -> 
                    {To, ToTag}
            end
    end,
    ReasonPhrase = nksip_lib:get_binary(reason_phrase, Opts),
    Resp1 = Req#sipmsg{
        id = nksip_lib:uid(),
        class = {resp, Code, ReasonPhrase},
        vias = Vias1,
        to = {To1, ToTag1},
        forwards = 70,
        cseq = {CSeqNum, Method},
        routes = [],
        contacts = [],
        headers = [],
        content_type = undefined,
        supported = [],
        require = [],
        expires = undefined,
        event = undefined,
        body = <<>>
    },
    ConfigOpts = AppId:config_uas(),
    try
        {Resp2, RespOpts2} = parse_opts(ConfigOpts, Resp1, [], Req, Code),
        Opts1 = case RUri#uri.scheme of
            sips ->
                [secure|Opts];
            _ ->
                case Routes of
                    [#uri{scheme=sips}|_] -> 
                        [secure|Opts];
                    [] ->
                        case Contacts of
                            [#uri{scheme=sips}|_] -> [secure|Opts];
                            _ -> Opts
                        end;
                    _ ->
                        Opts
                end
        end,
        Opts2 = case 
            Method=='INVITE' andalso Code>100 andalso Code<200
            andalso lists:member(<<"100rel">>, Require) 
        of
            true -> [do100rel|Opts1];
            false -> Opts1
        end,
        {Resp3, RespOpts3} = parse_opts(Opts2, Resp2, RespOpts2, Req, Code),
        {ok, Resp3, RespOpts3}
    catch
        throw:Throw -> {error, Throw}
    end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private If the Request-URI has a value we have placed on a Record-Route header, 
% change it to the last Route header and remove it. This gets back the original 
% RUri "stored" at the end of the Route header when proxing through a strict router
% This could happen if
% - in a previous request, we added a Record-Route header with our ip
% - the response generated a dialog
% - a new in-dialog request has arrived from a strict router, that copied our Record-Route
%   in the ruri
strict_router(#sipmsg{app_id=AppId, ruri=RUri, routes=Routes}=Request) ->
    case 
        nksip_lib:get_value(<<"nksip">>, RUri#uri.opts) /= undefined 
        andalso nksip_transport:is_local(AppId, RUri) of
    true ->
        case lists:reverse(Routes) of
            [] ->
                Request;
            [RUri1|RestRoutes] ->
                ?call_notice("recovering RURI from strict router request", []),
                Request#sipmsg{ruri=RUri1, routes=lists:reverse(RestRoutes)}
        end;
    false ->
        Request
    end.    


%% @private If RUri has a maddr address that corresponds to a local ip and has the 
% same transport class and local port than the transport, change the Ruri to
% this address, default port and no transport parameter
ruri_has_maddr(#sipmsg{
                    app_id = AppId, 
                    ruri = RUri, 
                    transport=#transport{proto=Proto, local_port=LPort}
                } = Request) ->
    case nksip_lib:get_binary(<<"maddr">>, RUri#uri.opts) of
        <<>> ->
            Request;
        MAddr -> 
            case nksip_transport:is_local(AppId, RUri#uri{domain=MAddr}) of
                true ->
                    case nksip_parse:transport(RUri) of
                        {Proto, _, LPort} ->
                            RUri1 = RUri#uri{
                                port = 0,
                                opts = nksip_lib:delete(RUri#uri.opts, 
                                                        [<<"maddr">>, <<"transport">>])
                            },
                            Request#sipmsg{ruri=RUri1};
                        _ ->
                            Request
                    end;
                false ->
                    Request
            end
    end.


%% @private
-spec parse_opts(nksip_lib:optslist(), nksip:response(), nksip_lib:optslist(),
                 nksip:request(), nksip:response_code()) -> 
    {nksip:response(), nksip_lib:optslist()}.

parse_opts([], Resp, Opts, _Req, _Code) ->
    {Resp, Opts};


parse_opts([Term|Rest], Resp, Opts, Req, Code) ->
    #sipmsg{app_id=AppId} = Req,
    Op = case Term of
    
        ignore ->
            ignore;

         % Header manipulation
        {add, Name, Value} -> {add, Name, Value};
        {add, {Name, Value}} -> {add, Name, Value};
        {replace, Name, Value} -> {replace, Name, Value};
        {replace, {Name, Value}} -> {replace, Name, Value};
        {insert, Name, Value} -> {insert, Name, Value};
        {insert, {Name, Value}} -> {insert, Name, Value};

        {Name, Value} when Name==from; Name==to; Name==content_type; 
                           Name==require; Name==supported; 
                           Name==expires; Name==contact; Name==route; 
                           Name==reason; Name==event ->
            {replace, Name, Value};

        % Already processed
        {Name, _} when Name==reason_phrase ->
            ignore;

        % Special parameters
        timestamp ->
            case nksip_sipmsg:header(Req, <<"timestamp">>, integers) of
                [Time] -> {replace, <<"timestamp">>, Time};
                _Config -> ignore
            end;
        do100rel ->
            case lists:member(<<"100rel">>, Req#sipmsg.supported) of
                true -> 
                    case lists:keymember(require, 1, Opts) of
                        true -> 
                            move_to_last;
                        false ->
                            #sipmsg{require=Require} = Resp,
                            Require1 = nksip_lib:store_value(<<"100rel">>, Require),
                            Resp1 = Resp#sipmsg{require=Require1},
                            {update, Resp1, [rseq|Opts]}
                    end;
                false -> 
                    ignore
            end;

        {body, Body} ->
            case lists:keymember(content_type, 1, Rest) of
                false ->
                    ContentType = case Resp#sipmsg.content_type of
                        undefined when is_binary(Body) -> undefined;
                        undefined when is_list(Body), is_integer(hd(Body)) -> undefined;
                        undefined when is_record(Body, sdp) -> <<"application/sdp">>;
                        undefined -> <<"application/nksip.ebf.base64">>;
                        CT0 -> CT0
                    end,
                    {update, Resp#sipmsg{body=Body, content_type=ContentType}, Opts};
                true ->
                    move_to_last
            end;
        {to_tag, _} when Code==100 ->
            ignore;
        {to_tag, ToTag} when is_binary(ToTag) ->
            #sipmsg{to={#uri{ext_opts=ExtOpts}=To, _}} = Resp,
            ExtOpts1 = nksip_lib:store_value(<<"tag">>, ToTag, ExtOpts),
            {update, Resp#sipmsg{to={To#uri{ext_opts=ExtOpts1}, ToTag}}, Opts};


        %% Pass-through options
        _ when Term==contact; Term==no_dialog; Term==secure; Term==rseq ->
            {update, Resp, [Term|Opts]};
        {local_host, auto} ->
            {update, Resp, [{local_host, auto}|Opts]};
        {local_host, Host} ->
            {update, Resp, [{local_host, nksip_lib:to_host(Host)}|Opts]};
        {local_host6, auto} ->
            {update, Resp, [{local_host6, auto}|Opts]};
        {local_host6, Host} ->
            case nksip_lib:to_ip(Host) of
                {ok, HostIp6} -> 
                    % Ensure it is enclosed in `[]'
                    {update, Resp, [{local_host6, nksip_lib:to_host(HostIp6, true)}|Opts]};
                error -> 
                    {update, Resp, [{local_host6, nksip_lib:to_binary(Host)}|Opts]}
            end;

        %% Automatic header generation (replace existing headers)
        user_agent ->
            {replace, <<"user-agent">>, <<"NkSIP ", ?VERSION>>};
        supported ->
            Supported = AppId:config_supported(),
            {replace, <<"supported">>, Supported};
        allow ->        
            {replace, <<"allow">>, AppId:config_allow()};
        accept ->
            #sipmsg{class={req, Method}} = Req,
            Accept = case AppId:config_accept() of
                undefined when Method=='INVITE'; Method=='UPDATE'; Method=='PRACK' ->
                    <<"application/sdp">>;
                undefined ->
                    ?ACCEPT;
                Accept0 ->
                    Accept0
            end, 
            {replace, <<"accept">>, Accept};
        date ->
            Date = nksip_lib:to_binary(httpd_util:rfc1123_date()),
            {replace, <<"date">>, Date};
        allow_event ->
            case AppId:config_events() of
                [] -> ignore;
                Events -> {replace, <<"allow-event">>, Events}
            end;

        % Authentication generation
        www_authenticate ->
            #sipmsg{from={#uri{domain=FromDomain}, _}} = Req,
            {add, <<"www-authenticate">>, nksip_auth:make_response(FromDomain, Req)};
        {www_authenticate, Realm} when is_binary(Realm) ->
            {add, <<"www-authenticate">>, nksip_auth:make_response(Realm, Req)};
        {www_authenticate, Realm, Nonce} when is_binary(Realm) andalso is_binary(Nonce) ->
            {add, <<"www-authenticate">>, nksip_auth:make_response(Realm, Req, Nonce)};
        proxy_authenticate ->
            #sipmsg{from={#uri{domain=FromDomain}, _}} = Req,
            {add, <<"proxy-authenticate">>, nksip_auth:make_response(FromDomain, Req)};
        {proxy_authenticate, Realm} when is_binary(Realm) ->
            {add, <<"proxy-authenticate">>, nksip_auth:make_response(Realm, Req)};
        {proxy_authenticate, Realm, Nonce} when is_binary(Realm) andalso is_binary(Nonce) ->
            {add, <<"proxy-authenticate">>, nksip_auth:make_response(Realm, Req, Nonce)};

        {service_route, Routes} when Code>=200, Code<300, 
                                     element(2, Req#sipmsg.class)=='REGISTER' ->
            case nksip_parse:uris(Routes) of
                error -> throw({invalid, service_route});
                Uris -> {replace, <<"service-route">>, Uris}
            end;
        {service_route, _} ->
            ignore;

        % Publish options
        {sip_etag, ETag} ->
            {replace, <<"sip-etag">>, nksip_lib:to_binary(ETag)};

        {Name, _} ->
            throw({invalid, Name});
        _ ->
            throw({invalid, Term})
    end,
    case Op of
        {add, AddName, AddValue} ->
            PName = nksip_parse_header:name(AddName), 
            PResp = nksip_parse_header:parse(PName, AddValue, Resp, post),
            parse_opts(Rest, PResp, Opts, Req, Code);
        {replace, RepName, RepValue} ->
            PName = nksip_parse_header:name(RepName), 
            PResp = nksip_parse_header:parse(PName, RepValue, Resp, replace),
            parse_opts(Rest, PResp, Opts, Req, Code);
        {insert, InsName, InsValue} ->
            PName = nksip_parse_header:name(InsName), 
            PResp = nksip_parse_header:parse(PName, InsValue, Resp, pre),
            parse_opts(Rest, PResp, Opts, Req, Code);
        {update, UpdResp, UpdOpts} -> 
            parse_opts(Rest, UpdResp, UpdOpts, Req, Code);
        % {retry, RetTerm} ->
        %     parse_opts([RetTerm|Rest], Resp, Opts, Req, Code);
        move_to_last ->
            parse_opts(Rest++[Term], Resp, Opts, Req, Code);
        ignore ->
            parse_opts(Rest, Resp, Opts, Req, Code)
    end.
