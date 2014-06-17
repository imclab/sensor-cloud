%% @author Georgios Koutsoumpakis, Li Hao
%% [www.csproj13.student.it.uu.se]
%% @version 1.0
%% @copyright [Copyright information]

%% @doc Webmachine_resource for /users

-module(users).
-export([init/1,
		 allowed_methods/2,
         content_types_accepted/2,
         content_types_provided/2,
         delete_resource/2,
         put_user/2,
         get_user/2,
         process_post/2,
		 delete_streams_with_user_id/1]).

-include("webmachine.hrl").
-include_lib("erlastic_search.hrl").
-include("field_restrictions.hrl").

%% @doc
%% Function: init/1
%% Purpose: init function used to fetch path information from webmachine dispatcher.
%% Returns: {ok, undefined}
%% @end
-spec init([]) -> {ok, undefined}.
init([]) ->
        {ok, undefined}.



%% @doc
%% Function: allowed_methods/2
%% Purpose: init function used to fetch path information from webmachine dispatcher.
%% Returns: {ok, undefined}
%% @end
-spec allowed_methods(ReqData::tuple(), State::string()) -> {list(), tuple(), string()}.
allowed_methods(ReqData, State) ->
    case api_help:parse_path(wrq:path(ReqData)) of
        [{"auth","openid"}] ->
            {['POST'], ReqData, State};
        [{"users","_search"}] ->
            {['POST','GET'], ReqData, State};
        [{"users",_Id}] ->
            {['GET', 'PUT', 'DELETE'], ReqData, State};
        [{"users",_Id},{"_subscribe"}] ->
            {['PUT'], ReqData, State};
        [{"users",_Id},{"_unsubscribe"}] ->
            {['PUT'], ReqData, State};
        [{"users"}] ->
            {['POST','GET'], ReqData, State};
        [error] ->
            {[], ReqData, State}
    end.



%% @doc
%% Function: content_types_provided/2
%% Purpose: based on the Accept header on a 'GET' request, we provide different media types to the client.
%% A code 406 is returned to the client if we cannot return the media-type that the user has requested.
%% Returns: {[{Mediatype, Handler}], ReqData, State}
%% @end
-spec content_types_provided(ReqData::tuple(), State::string()) -> {list(), tuple(), string()}.
content_types_provided(ReqData, State) ->
        {[{"application/json", get_user}], ReqData, State}.


%% @doc
%% Function: content_types_accepted/2
%% Purpose: based on the content-type on a 'POST' or 'PUT', we know which kind of data that is allowed to be sent to the server.
%% A code 406 is returned to the client if we don't accept a media type that the client has sent.
%% Returns: {[{Mediatype, Handler}], ReqData, State}
%% @end
-spec content_types_accepted(ReqData::tuple(), State::string()) -> {list(), tuple(), string()}.
content_types_accepted(ReqData, State) ->
        {[{"application/json", put_user}], ReqData, State}.


%% @doc
%% Function: delete_resource/2
%% Purpose: Works but need to fix transformation of the return value
%% Returns: {JSON-object(string), ReqData, State}
%%
%% Side effects: Deletes the User for the database
%% @end
-spec delete_resource(ReqData::tuple(), State::string()) -> {string(), tuple(), string()}.
delete_resource(ReqData, State) ->
    Id = id_from_path(ReqData),
    case delete_streams_with_user_id(Id) of
        {error, {Code, Body}} ->
            ErrorString = api_help:generate_error(Body, Code),
            {{halt, Code}, wrq:set_resp_body(ErrorString, ReqData), State};
        {ok} ->
			case erlastic_search:delete_doc(?INDEX,"user", Id) of
				{error, {Code, Body}} ->
					ErrorString = api_help:generate_error(Body, Code),
					{{halt, Code}, wrq:set_resp_body(ErrorString, ReqData), State};
				{ok,List} ->
					{true,wrq:set_resp_body(lib_json:encode(List),ReqData),State}
			end
    end.



%% @doc
%% Function: delete_streams_with_user_id/1
%% Purpose: Deletes the streams and/or virtual streams with the given user id,
%% Returns:  ERROR = {error,Errorcode}
%%			 OK = {ok}
%% @end
-spec delete_streams_with_user_id(Id::string()) -> term().

delete_streams_with_user_id(Id) ->
	api_help:refresh(),
	Query = "user_id:" ++ Id,
	erlang:display("the query is: "++Query),
	case erlastic_search:search_limit(?INDEX, "stream", Query,500) of
		{error,Reason} ->
			{error,Reason};
		{ok,List} ->
			case get_streams(List) of
				[] -> erlang:display("the length of list is zero"),
					  {ok};
				Streams ->
					case delete_streams(Streams, "stream") of
						{error,Reason} -> {error, Reason};
						{ok} -> {ok}
					end
			end
	end,
	case erlastic_search:search_limit(?INDEX, "virtual_stream", Query, 500) of
		{error,Reason2} ->
			{error,Reason2};
		{ok,List2} ->
			case get_streams(List2) of
				[] -> {ok};
				VStreams ->
					case delete_streams(VStreams, "virtual_stream") of
						{error,Reason2} -> {error, Reason2};
						{ok} -> {ok}
					end
			end
	end.

%% @doc
%% Function: get_streams/1
%% Purpose: get a list of ids of a list of JSON objects
%% Returns:  a list with the ids of the JSON objects given
%% @end
-spec get_streams(JSON::string()) -> list().

get_streams(JSON) when is_tuple(JSON)->
	Result = lib_json:get_field(JSON, "hits.hits"),
	get_streams(Result);
get_streams(undefined) ->
	[];
get_streams([]) ->
	[];
get_streams([JSON | Tl]) ->
	case lib_json:get_field(JSON, "_id") of
		undefined -> [];
		Id -> [Id] ++ get_streams(Tl)
	end.



%% @doc
%% Function: delete_streams/2
%% Purpose: Deletes all streams in the given list, the list elements are streamIds as binaries
%% Returns:  ok, or {{error,_Reason}, StreamId, Rest} where StreamId is the binary Id of the stream for which deletion failed
%% @end
delete_streams([], Type) -> {ok};
delete_streams([StreamId|Rest], Type) ->
	case Type of
		"stream" ->
			case erlastic_search:get_doc(?INDEX, "stream", StreamId) of
				{error, {Code2, Body2}} -> {error, {Code2, Body2}};
				{ok,JsonStruct} ->
					SubsList = lib_json:get_field(JsonStruct, "_source.subscribers"),
					streams:delete_stream_id_from_subscriptions(StreamId,SubsList)
			end;
		_ ->
			ok
	end,
	case streams:delete_data_points_with_stream_id(StreamId, Type) of
		{error,{Code, Body}} ->
			{error,{Code, Body}};
		{ok} ->
			case erlastic_search:delete_doc(?INDEX, Type, StreamId) of
				{error,Reason} -> {error,Reason};
				{ok,_List} ->
					% terminate the poller
					case whereis(polling_supervisor) of
						undefined->
							continue;
						_->
							gen_server:cast(polling_supervisor, {terminate, binary_to_list(StreamId)})
					end,
					delete_streams(Rest, Type)
			end
	% change ends
	end.


%% @doc
%% Function: put_user/2
%% Purpose: Replaces a User in the database with the new info.
%% It is run automatically for PUT requests
%% Returns: {true, ReqData, State} || {{error, Reason}, ReqData, State}
%%
%% Side effects: Updates the User in the database
%% @end
-spec put_user(ReqData::tuple(), State::string()) -> {true, tuple(), string()}.
put_user(ReqData, State) ->
	case api_help:is_subs(ReqData) or api_help:is_unsubs(ReqData) of
		false ->
		    Id = id_from_path(ReqData),
			{UserJson,_,_} = api_help:json_handler(ReqData, State),
		    %check if doc already exists
			case {api_help:do_any_field_exist(UserJson,?RESTRCITEDUPDATEUSERS),api_help:do_only_fields_exist(UserJson,?ACCEPTEDFIELDSUSERS)} of
				{true,_} ->
					ResFields1 = lists:foldl(fun(X, Acc) -> X ++ ", " ++ Acc end, "", ?RESTRCITEDUPDATEUSERS),
					ResFields2 = string:sub_string(ResFields1, 1, length(ResFields1)-2),
					{{halt,409}, wrq:set_resp_body("{\"error\":\"Error caused by restricted field in document, these fields are restricted : " ++ ResFields2 ++"\"}", ReqData), State};
				{false,false} ->
					{{halt,403}, wrq:set_resp_body("Unsupported field(s)", ReqData), State};
				{false,true} ->
					Update = lib_json:set_attr(doc,UserJson),
					case api_help:update_doc(?INDEX, "user", Id, Update) of
						{error, {Code, Body}} ->
							ErrorString = api_help:generate_error(Body, Code),
							{{halt, Code}, wrq:set_resp_body(ErrorString, ReqData), State};
						{ok, Json} ->
							{true, wrq:set_resp_body(lib_json:encode(Json), ReqData), State}
					end
			end;
		true ->
			erlang:display("SUBSCRIPTION!"),
			Id = id_from_path(ReqData),
			{Json,_,_} = api_help:json_handler(ReqData,State),
			StreamId = case lib_json:get_field(Json,"stream_id") of
							undefined ->
			                	ErrorString = api_help:generate_error(<<"{\"error\":\"Error, incorrect or no stream specified.\"}">>, 409),
			        			{{halt, 409}, wrq:set_resp_body(ErrorString, ReqData), State};
							Stream ->
								Stream
        				end,

			case erlastic_search:get_doc(?INDEX, "user", Id) of
				{error, {Code, Body}} -> %User doesn't exist
					ErrorString2 = api_help:generate_error(Body, Code),
					{{halt, Code}, wrq:set_resp_body(ErrorString2, ReqData), State};
				{ok,List} ->	%User exists
						SubsList = lib_json:get_field(List, "_source.subscriptions"),
						case api_help:is_unsubs(ReqData) of
							true ->
									case find_subscription(StreamId, SubsList) of
										found -> %User has NOT subscribed to this stream before
											case remove_subscriber(StreamId, Id) of
												{error, {Code, Body}} ->

													ErrorString3 = api_help:generate_error(Body, Code),
					            					{{halt, Code}, wrq:set_resp_body(ErrorString3, ReqData), State};
				            					ok ->
				            						UpdateJson = "{\"script\" : \"ctx._source.subscriptions.remove(subscription)\",\"params\":{\"subscription\":{ \"stream_id\":\""++binary_to_list(StreamId)++"\"}}}",
													case api_help:update_doc(?INDEX, "user", Id, UpdateJson,[]) of
														{error, {Code, Body}} ->

					            							ErrorString4 = api_help:generate_error(Body, Code),
					            							{{halt, Code}, wrq:set_resp_body(ErrorString4, ReqData), State};
					            						{ok, List3} -> {true,wrq:set_resp_body(lib_json:encode(List3),ReqData),State}
				            						end
				            				end;
										not_found -> %User HAS subscribed to this stream before
					            			{{halt, 409}, wrq:set_resp_body("{\"ok\": false, \"error\" : \"Not subscribed\"}", ReqData), State}
					            	end;
							false ->
								case find_subscription(StreamId, SubsList) of
									not_found -> %User has NOT subscribed to this stream before
										case add_subscriber(StreamId, Id) of
											{error, {Code, Body}} ->
												ErrorString3 = api_help:generate_error(Body, Code),
				            					{{halt, Code}, wrq:set_resp_body(ErrorString3, ReqData), State};
			            					ok ->
			            						UpdateJson = "{\"script\" : \"ctx._source.subscriptions += subscription\",\"params\":{\"subscription\":{ \"stream_id\":\""++binary_to_list(StreamId)++"\"}}}",
												case api_help:update_doc(?INDEX, "user", Id, UpdateJson,[]) of
													{error, {Code, Body}} ->
				            							ErrorString4 = api_help:generate_error(Body, Code),
				            							{{halt, Code}, wrq:set_resp_body(ErrorString4, ReqData), State};
				            						{ok, List3} -> {true,wrq:set_resp_body(lib_json:encode(List3),ReqData),State}
			            						end
			            				end;
									found -> %User HAS subscribed to this stream before
				            			{{halt, 409}, wrq:set_resp_body("{\"ok\": false, \"error\" : \"Already subscribed\"}", ReqData), State}
								end
						end
				end
		end.


%% @doc
%% Function: find_subscription/1
%% Purpose: Used to find a stream in a list of subscriptions(list of JSON objects)
%% based on a stream_id
%%
%% Returns: Found/Not found
%% @end
find_subscription(StreamId, Subscriptions) when is_list(StreamId) ->
	find_subscription(binary:list_to_bin(StreamId), Subscriptions);
find_subscription(StreamId, []) ->
	not_found;
find_subscription(StreamId, [Head|Rest]) ->
	case lib_json:get_field(Head, "stream_id") of
		StreamId ->
			found;
		_ ->
			find_subscription(StreamId, Rest)
	end.



%% @doc
%% Function: add_subscriber/2
%% Purpose: Used to add a new subscriber to a stream
%%          in ES
%%
%% @end
-spec add_subscriber(StreamId::string(), UserId::string()) -> ok | {error, no_model}.

add_subscriber(StreamId, UserId) ->
	UpdateJson = "{\"script\" :\"{ctx._source.nr_subscribers += 1; ctx._source.subscribers += subscriber};\",
					\"params\":{\"subscriber\":{ \"user_id\":\""++UserId++"\"}}}",
	case api_help:update_doc(?INDEX, "stream",StreamId, UpdateJson,[]) of
			{error, {Code, Body}} -> {error, {Code, Body}};
			{ok, _} -> 	ok
	end.



	%% @doc
%% Function: remove_subscriber/2
%% Purpose: Used to remove a new subscriber to a stream
%%          in ES
%%
%% @end
-spec remove_subscriber(StreamId::string(), UserId::string()) -> ok | {error, no_model}.

remove_subscriber(StreamId, UserId) ->
	UpdateJson = "{\"script\" :\"{ctx._source.nr_subscribers += -1; ctx._source.subscribers.remove(subscriber)};\",
						\"params\":{\"subscriber\":{ \"user_id\":\""++UserId++"\"}}}",
	case api_help:update_doc(?INDEX, "stream",StreamId, UpdateJson,[]) of
			{error, {Code, Body}} -> {error, {Code, Body}};
			{ok, _} -> 	ok
	end.

%% @doc
%% Function: process_post/2
%% Purpose: decodes a JSON object and either adds the new User in the DB or
%% performs search in the User database.
%% It is run automatically for POST requests
%% Returns: {true, ReqData, State} || {{error, Reason}, ReqData, State}
%%
%% Side effects: Inserts a new User in the database (when for insertion)
%% @end
-spec process_post(ReqData::tuple(), State::string()) -> {true, tuple(), string()}.
process_post(ReqData, State) ->
    case api_help:is_search(ReqData) of
        false ->
        	case api_help:is_auth(ReqData) of
        		false ->
					{UserJson,_,_} = api_help:json_handler(ReqData, State),
					create_user_if_valid(UserJson, ReqData, State);
				true ->
					{AuthJson,_,_} = api_help:json_auth_handler(ReqData, State),
					process_auth_openid(AuthJson,ReqData,State);
		    end;
        true ->
            process_search(ReqData,State, post)
    end.

-spec create_user_if_valid(UserJson::boolean(), ReqData::tuple(), State::string()).
create_user_if_valid(UserJson, ReqData, State) ->
	case lib_json:get_field(UserJson, "username") of
		undefined ->
			UserName = undefined,
			UserNameApproved = false;
		UserBinary ->
			%% CHECK AND SANITIZE USERNAME
			UserName = string:to_lower(binary_to_list(UserBinary)),
			UserNameApproved = case lists:filter(fun(X) -> not lists:member(X, "abcdefghijklmnopqrstuvwxyz_-0123456789") end,UserName) of
				"" ->
					case erlastic_search:get_doc(?INDEX, "user", UserName) of
						{error, {404, _}} ->
            				true;
        				{error, {Code0, Body0}} ->
							{Code0, Body0};
						{ok,JsonStruct} ->
							false
					end;
				_ ->
					invalidcharacters
			end
	end,
	case {api_help:do_only_fields_exist(UserJson,?ACCEPTEDFIELDSUSERS),UserNameApproved,UserName =/= undefined} of
  		{_,_,false} ->
	  		{{halt,403}, wrq:set_resp_body("Username missing", ReqData), State};
		{false,_,_} ->
			{{halt,403}, wrq:set_resp_body("Unsupported field(s)", ReqData), State};
		{true,false,_} ->
			{{halt,409}, wrq:set_resp_body("Non unique username given", ReqData), State};
		{true,invalidcharacters,_} ->
			{{halt,409}, wrq:set_resp_body("Invalid characters in username. You may only use a-z, 0-9, _ and -", ReqData), State};
		{true,{Code1,Body1},_} ->
			ErrorString1 = api_help:generate_error(Body1, Code1),
            {{halt, Code1}, wrq:set_resp_body(ErrorString1, ReqData), State};
		{true,true,_} ->
			NewUserJson = lib_json:replace_field(UserJson, "username", list_to_binary(UserName)),
            FieldsAdded = add_server_side_fields(NewUserJson),
			case erlastic_search:index_doc_with_id(?INDEX, "user", UserName, FieldsAdded) of
				{error, {Code2, Body2}} ->
					ErrorString2 = api_help:generate_error(Body2, Code2),
            		{{halt, Code2}, wrq:set_resp_body(ErrorString2, ReqData), State};
        		{ok,List} ->
            		{true, wrq:set_resp_body(lib_json:encode(List), ReqData), State}
			end
    end.

%% @doc
%% Function: get_user/2
%% Purpose: Returns the JSON representation of a json-object or multiple json-objects.
%% Returns: {true, ReqData, State} | {false, ReqData, State}
%% @end
-spec get_user(ReqData::tuple(), State::string()) -> {list(), tuple(), string()}.
get_user(ReqData, State) ->
    case api_help:is_search(ReqData) of
        false ->
            case id_from_path(ReqData) of
                undefined ->
                    % Get all users
                    case wrq:get_qs_value("size",ReqData) of
                        undefined ->
							case erlastic_search:count_type(?INDEX, "user") of
								{error, {_CountCode, _CountBody}} ->
									Size = 100;
								{ok,CountJsonStruct} ->
									Size = lib_json:get_field(CountJsonStruct,"count")
							end;
                        SizeParam ->
                            Size = list_to_integer(SizeParam)
                    end,
                    case wrq:get_qs_value("admin",ReqData) of
                        "true" ->
                        	Query = "{\"size\" :" ++ integer_to_list(Size) ++",\"query\" : {\"match_all\" : {}},\"fields\":[\"password\",\"_source\"]}}";
                        _ ->
                            Query = "{\"size\" :" ++ integer_to_list(Size) ++",\"query\" : {\"match_all\" : {}},\"filter\" : {\"bool\":{\"must_not\":{\"term\":{\"private\":\"true\"}}}}}"
                    end,
					case erlastic_search:search_json(#erls_params{},?INDEX, "user", Query) of
                        {error, {Code, Body}} ->
                            ErrorString = api_help:generate_error(Body, Code),
                            {{halt, Code}, wrq:set_resp_body(ErrorString, ReqData), State};
					    {ok,JsonStruct} ->
						    FinalJson = api_help:get_list_and_add_password(JsonStruct),
						    {FinalJson, ReqData, State}
                    end;
                Id ->
				    %% Get specific user
					case erlastic_search:get_doc(?INDEX, "user", string:to_lower(Id), [{<<"fields">>, <<"password,_source">>}]) of
						{error, {Code1, Body1}} ->
							ErrorString1 = api_help:generate_error(Body1, Code1),
							{{halt, Code1}, wrq:set_resp_body(ErrorString1, ReqData), State};
						{ok,JsonStruct} ->
							FinalJson = api_help:get_and_add_password(JsonStruct),
							{FinalJson, ReqData, State}
					end
            end;
        true ->
            process_search(ReqData,State, get)
    end.



%% @doc
%% Function: process_auth_openid/2
%% Purpose: Does authentication of users based on the OpenID Connect protocol via POST method
%% Returns: {true, ReqData, State} || {{error, Reason}, ReqData, State}
%% @end
-spec process_auth_openid(AuthJson::boolean(), ReqData::tuple(), State::string()) -> {list(), tuple(), string()}.
process_auth_openid(AuthJson, ReqData, State) ->
	% Get the access_token
	% Send the request agains the IdP (google)
	% Fetch the user's data
	% Create user if valid
	% Return
	{true, wrq:set_resp_body(lib_json:encode(List),ReqData), State}.



%% @doc
%% Function: process_search/3
%% Purpose: Does search for Users for either search done with POST or GET
%% Returns: {true, ReqData, State} || {{error, Reason}, ReqData, State}
%% @end
-spec process_search(ReqData::tuple(), State::string(), term()) ->
                 {list(), tuple(), string()}.
process_search(ReqData, State, post) ->
        {Json,_,_} = api_help:json_handler(ReqData,State),
		FinalQuery = "{\"query\" : {\"term\" : " ++ Json ++ "},\"filter\" : {\"bool\":{\"must_not\":{\"term\":{\"private\":\"true\"}}}}}",
        case erlastic_search:search_json(#erls_params{},?INDEX, "user", FinalQuery) of
            {error, {Code, Body}} ->
                ErrorString = api_help:generate_error(Body, Code),
                {{halt, Code}, wrq:set_resp_body(ErrorString, ReqData), State};
            {ok,List} ->
                {true, wrq:set_resp_body(lib_json:encode(List),ReqData),State}
        end;
process_search(ReqData, State, get) ->
        TempQuery = wrq:req_qs(ReqData),
        TransformedQuery = api_help:transform(TempQuery),
		TermQuery = api_help:make_term_query(TransformedQuery),
		FinalQuery = "{\"query\" : {\"term\" : " ++ TermQuery ++ "},\"filter\" : {\"bool\":{\"must_not\":{\"term\":{\"private\":\"true\"}}}}}",
        case erlastic_search:search_json(#erls_params{},?INDEX, "user", FinalQuery) of
            {error, {Code, Body}} ->
                ErrorString = api_help:generate_error(Body, Code),
                {{halt, Code}, wrq:set_resp_body(ErrorString, ReqData), State};
            {ok,List} ->
                {lib_json:encode(List),ReqData,State} % May need to convert
        end.





%% @doc
%% Function: id_from_path/2
%% Purpose: Retrieves the id from the path.
%% Returns: Id
%% @end
-spec id_from_path(string()) -> string().
id_from_path(RD) ->
    case wrq:path_info(id, RD) of
        undefined ->
            case string:tokens(wrq:disp_path(RD), "/") of
                ["users", Id] ->string:to_lower(Id);
                _ -> undefined
            end;
        Id ->  string:to_lower(Id)
    end.

%% @doc
%% Function: add_server_side_fields/1
%% Purpose: Used to add all the fields that should be added server side
%% Returns: The new json with the fields added
%% @end
-spec add_server_side_fields(Json::string()) -> string().

add_server_side_fields(Json) ->
	lib_json:add_values(Json,[{rankings, "[]"},{notifications,"[]"},{triggers,"[]"},{subscriptions, "[]"}]).



