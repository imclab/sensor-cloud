%% @author Jacob Koutsoumpakis
%%   [www.csproj13.student.it.uu.se]
%% @version 1.0
%% @copyright [Copyright information]
%% This module will contain all functions needed to handle 
%% http requests done to the webmachine regarding virtual streams 
%%
%% @end

-module(virtual_streams).
-export([init/1, allowed_methods/2, content_types_provided/2,
		 process_post/2]).

-include_lib("erlastic_search.hrl").
-include("webmachine.hrl").

-define(INDEX, "sensorcloud").

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
		[{"vstreams"}] ->
			{['POST'], ReqData, State}; 
		[{"vstreams", _Id}] -> %to be removed?
			{['POST'], ReqData, State};
		[{"vstreams", _Id}, {"data"}] -> %do we need this?
			{['POST', 'DELETE'], ReqData, State};
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
		{[{"application/json", get_datapoint}], ReqData, State}.

%% @doc
%% Function: process_post/2
%% Purpose: decodes a JSON object and either adds the new datapoint in the DB or
%% performs search in the Datapoint database.
%% It is run automatically for POST requests
%% Returns: {true, ReqData, State} || {{error, Reason}, ReqData, State}
%%
%% Side effects: Inserts a new Datapoint in the database (when for insertion)
%% @end
-spec process_post(ReqData::tuple(), State::string()) -> {true, tuple(), string()}.
process_post(ReqData, State) ->
	{VirtualStreamJson,_,_} = api_help:json_handler(ReqData, State),
	{{Year,Month,Day},{Hour,Minute,Second}} = calendar:local_time(),
	Date = api_help:generate_timestamp([Year,Month,Day],0), % it is crashing if I add Hour, Minute, Second
	DateAdded = api_help:add_field(VirtualStreamJson,"creation_date",Date),
	case erlastic_search:index_doc(?INDEX, "vstream", DateAdded) of	
		{error, Reason} -> 
			VirtualStreamId = "x86vOMKiSIyLd5pQXDYi8w",	% to be fixed to do a good check
			{{error,Reason}, wrq:set_resp_body("{\"error\":\""++ atom_to_list(Reason) ++ "\"}", ReqData), State};
		{ok,List} -> 
			VirtualStreamId = lib_json:get_field(List, "_id"),
			{true, wrq:set_resp_body(lib_json:encode(List), ReqData), State}
	end,
	%these should be in the ok case of index_doc?
	StreamsInvolved = lib_json:get_field(VirtualStreamJson, "streams_involved"),
	TimestampFrom = lib_json:get_field(VirtualStreamJson, "timestampfrom"),
	Function = lib_json:get_field(VirtualStreamJson, "function"),
	reduce(VirtualStreamId, StreamsInvolved, TimestampFrom, Function, ReqData, State)
	.


%% @doc
%% Function: reduce/6
%% Purpose: Gets information about which streams will be used and 
%% optionally a timestamp range, it executes a query and posts the datapoints returned
%% to the current virtual stream
%% Returns: {true, ReqData, State} || {{error, Reason}, ReqData, State}
-spec reduce(VirtualStreamId::string(), Streams::string(), TimestampFrom::string(), Function::string(), ReqData::tuple(), State::string()) -> %%should change to date type instead, also add ReqData, State
		  {true, tuple(), string()}.
reduce(VirtualStreamId, Streams, TimestampFrom, Function, ReqData, State) ->
	% (aggregated *) average, min, max, std deviation, count, sum of squares, variance
	Query = create_query(Function, Streams, TimestampFrom),
	% should also update the connection of vstream <--> streams
	
	
	case erlastic_search:search_json(#erls_params{},?INDEX, "datapoint", lib_json:to_string(Query)) of
		{error, Reason} -> {{error,Reason}, wrq:set_resp_body("{\"error\":\""++ atom_to_list(Reason) ++ "\"}", ReqData), State};
		{ok,JsonStruct} ->
			%%		check what happens if list is empty, improve with bulk posting
			%%   	{true,wrq:set_resp_body(lib_json:encode(FinalJson),ReqData),State},
			
			
			%Do we ever need to post all the data?
			%NewDatapoints = lists:map(fun(Json) -> 
			%							RmId = lib_json:get_field(Json, "_source"),
			%							FinalDatapoint = lib_json:replace_field(RmId, "streamid", VirtualStreamId),
			%						  	erlastic_search:index_doc(?INDEX, "datapoint", FinalDatapoint)
			%						 end, DatapointsList),


	% what do we store if whe do not aggregate and thus the statistics are only a single value?
			case string:str(Function, [<<"aggregate">>]) of %is aggregate the proper name? maybe groupby?
            	0 ->
					{{Year,Month,Day},{Hour,Minute,Second}} = calendar:local_time(),
					TimeStamp = api_help:generate_timestamp([Year,Month,Day,Hour,Minute,Second],0), % to be reconsidered
					Datapoint = lib_json:get_field(JsonStruct, "facets.statistics"),
					FinalDatapoint = lib_json:set_attrs([
														   {"timestamp", list_to_atom(TimeStamp)}, %does timestamp have a meaning here? maybe do a reverse search for the time???
														   {"stream_id", list_to_atom(binary_to_list(VirtualStreamId))},
														   {"value",  lib_json:get_field(Datapoint, binary_to_list(lists:nth(1, Function)))}
														  ]),
erlang:display(FinalDatapoint),
					case erlastic_search:index_doc(?INDEX, "datapoint", FinalDatapoint) of 
						{error, Reason2} -> erlang:display("Error");
						{ok,JsonStruct2} ->	erlang:display("Correct")						
					end;
				_->
					DatapointsList = lib_json:get_field(JsonStruct, "facets.statistics.entries"),
					NewDatapoints = lists:map(fun(Json) -> 
													  FinalDatapoint = lib_json:set_attrs([
																						   {"timestamp", list_to_atom(msToDate(lib_json:get_field(Json, "key")))},
																						   {"stream_id", VirtualStreamId},
																						   {"value",  lib_json:get_field(Json, binary_to_list(lists:nth(2, Function)))}
																						  ]),
													erlang:display(FinalDatapoint),
													  erlastic_search:index_doc(?INDEX, "datapoint", lib_json:to_string(FinalDatapoint)) %to add error check here
											  end, DatapointsList)
			
			%%will post all datapoints one by one, improve with bulk posting should be like the following
			%% 							case erlastic_search:bulk_index_docs(?INDEX, "datapoint", NewDatapoints) of
			%% 									{error, Reason} -> {{error,Reason}, wrq:set_resp_body("{\"error\":\""++ atom_to_list(Reason) ++ "\"}", ReqData), State};
			%% 									{ok,List} -> {true, wrq:set_resp_body(lib_json:encode(List), ReqData), State}
			%% 							end
			end,
			{true, wrq:set_resp_body("\"status\":\"ok\"", ReqData), State} %% need to fix message returned
	end.

 
%% @doc
%% Function: create_query/3
%% Purpose: Creates the query for the function specified
%% Returns: string()
%% @end
-spec create_query(Function::string(), Streams::string(), TimestampFrom::string()) -> {string()}.
create_query(Function, Streams, TimestampFrom) ->
	%size to be passed as a variable?? but it will not work in the terms facets query...
	Query = lib_json:set_attrs(
		  [{size, 100},
		   {"query", "{}"},
		   {"query.filtered", "{}"},
		   {"query.filtered.query", "{}"},
		   {"query.filtered.query.terms", "{}"},
		   {"query.filtered.query.terms.stream_id", Streams},
		   {"query.filtered.filter", "{}"},
		   {"query.filtered.filter.range", "{}"},
		   {"query.filtered.filter.range.timestamp", "{}"},
		   {"query.filtered.filter.range.timestamp.gte", TimestampFrom}
		  	
	]),
	case string:str(Function, [<<"aggregate">>]) of %is aggregate the proper name? maybe groupby?
            0 -> %	   	["min" "max" "mean" "???average???" "sum_of_squares" "variance" "std_deviation" ->
		  				%the following are without aggregation, just statistics   .
						%min, max etc are not added in the query yet, I will investigate if it is even possible
				Facet =  [{"facets", "{}"},
					  	 {"facets.statistics", "{}"},
					  	 {"facets.statistics.statistical", "{}"},
					  	 {"facets.statistics.statistical.script", '(Long) _source.value'}]; %I have to get the value here in another way
			_ -> %		["aggregate", "min" "max" "total(==sum)" ] ->		can also support custom calculations like *,+,-,/, ^(prob)
				% as above

				% the interval is also included in the function, in the 3rd position otherwise pick 10s??
				Interval = binary_to_list(lists:nth(3, Function)),
				Facet = [{"facets", "{}"},
						{"facets.statistics", "{}"},
						{"facets.statistics.histogram", "{}"},
						{"facets.statistics.histogram.key_field", 'timestamp'},
						{"facets.statistics.histogram.value_script", '(Long) _source.value'},
						{"facets.statistics.histogram.time_interval", list_to_atom(Interval)}]
	end,
	lib_json:add_values(Query, Facet)
.

%% @doc
%
%
msToDate(Milliseconds) ->
	BaseDate = calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
   	Seconds = BaseDate + (Milliseconds div 1000),
	Date = calendar:gregorian_seconds_to_datetime(Seconds),
	{{Year,Month,Day},{Hour,Minute,Second}} = Date,
	TimeStamp = api_help:generate_timestamp([Year,Month,Day,Hour,Minute,Second],0),
  	TimeStamp.

