alias Experimental.GenStage

defmodule GenStage do
  @moduledoc """
  Stages are computation steps that send and/or receive data
  from other stages.

  When a stage sends data, it acts as a producer. When it receives
  data, it acts as a consumer. Stages may take both producer and
  consumer roles at once.

  **Note:** this module is currently namespaced under
  `Experimental.GenStage`. You will need to `alias Experimental.GenStage`
  before writing the examples below.

  ## Stage types

  Besides taking both producer and consumer roles, a stage may be
  called "source" if it only produces items or called "sink" if it
  only consumes items.

  For example, imagine the stages below where A sends data to B
  that sends data to C:

      [A] -> [B] -> [C]

  we conclude that:

    * A is only a producer (and therefore a source)
    * B is both producer and consumer
    * C is only consumer (and therefore a sink)

  As we will see in the upcoming Examples section, we must
  specify the type of the stage when we implement each of them.

  To start the flow of events, we subscribe consumers to
  producers. Once the communication channel between them is
  established, consumers will ask the producers for events.
  We typically say the consumer is sending demand upstream.
  Once demand arrives, the producer will emit items, never
  emitting more items than the consumer asked for. This provides
  a back-pressure mechanism.

  A consumer may have multiple producers and a producer may have
  multiple consumers. When a consumer asks for data, each producer
  is handled separately, with its own demand. When a producer sends
  receives demand and sends data to multiple consumers, the demand
  is tracked and the events are sent by a dispatcher. This allows
  producers to send data using different "strategies". See
  `GenStage.Dispatcher` for more information.

  ## Example

  Let's define the simple pipeline below:

      [A] -> [B] -> [C]

  where A is a producer that will emit items starting from 0,
  B is a producer-consumer that will receive those items and
  multiply them by a given number and C will receive those events
  and print them to the terminal.

  Let's start with A. Since A is a producer, its main
  responsibility is to receive demand and generate events.
  Those events may be in memory or an external queue system.
  For simplicity, let's implement a simple counter starting
  from a given value of `counter` received on `init/1`:

      defmodule A do
        use GenStage

        def init(counter) do
          {:producer, counter}
        end

        def handle_demand(demand, counter) when demand > 0 do
          # If the counter is 3 and we ask for 2 items, we will
          # emit the items 3 and 4, and set the state to 5.
          events = Enum.to_list(counter..counter+demand-1)
          {:noreply, events, counter + demand}
        end
      end

  B is a producer-consumer. This means it does not explicitly
  handle the demand because the demand is always forwarded to
  its producer. Once A receives the demand from B, it will send
  events to B which will be transformed by B as desired. In
  our case, B will receive events and multiply them by a number
  giving on initialization and stored as the state:

      defmodule B do
        use GenStage

        def init(number) do
          {:producer_consumer, number}
        end

        def handle_events(events, _from, number) do
          events = Enum.map(events, & &1 * number)
          {:noreply, events, number}
        end
      end

  C will finally receive those events and print them every second
  to the terminal:

      defmodule C do
        use GenStage

        def init(:ok) do
          {:consumer, :the_state_does_not_matter}
        end

        def handle_events(events, _from, state) do
          # Wait for a second.
          :timer.sleep(1000)

          # Inspect the events.
          IO.inspect(events)

          # We are a consumer, so we would never emit items.
          {:noreply, [], state}
        end
      end

  Now we can start and connect them:

      {:ok, a} = GenStage.start_link(A, 0)   # starting from zero
      {:ok, b} = GenStage.start_link(B, 2)   # multiply by 2
      {:ok, c} = GenStage.start_link(C, :ok) # state does not matter

      GenStage.sync_subscribe(c, to: b)
      GenStage.sync_subscribe(b, to: a)

  Notice we typically subscribe from bottom to top. Since A will
  start producing items only when B connects to it, we want this
  subscription to happen when the whole pipeline is ready. After
  you subscribe all of them, demand will start flowing upstream and
  events downstream.

  When implementing consumers, we often set the `:max_demand` and
  `:min_demand` on subscription. The `:max_demand` specifies the
  maximum amount of events that must be in flow while the `:min_demand`
  specifies the minimum threshold to trigger for more demand. For
  example, if `:max_demand` is 1000 and `:min_demand` is 500
  (the default values), the consumer will ask for 1000 events initially
  and ask for more only after it receives at least 500.

  In the example above, B is a `:producer_consumer` and therefore
  acts as a buffer. Getting the proper demand values in B is
  important: making the buffer to small may make the whole pipeline
  slower, making the buffer too big may unecessarily consume
  memory.

  When such values are applied to the stages above, it is easy
  to see the producer works in batches. The producer A ends-up
  emitting batches of 50 items which will take approximately
  50 seconds to be consumed by C, which will then request another
  batch of 50 items.

  ## Buffer events

  Due to the concurrent nature of Elixir software, sometimes
  a producer may receive events without consumers to send those
  events to. For example, imagine a consumer C subscribes to
  producer B. Next, the consumer C sends demand to B, which sends
  the demand upstream. Now, if the consumer C crashes, B may
  receive the events from upstream but it no longer has a consumer
  to send those events to. In such cases, B will buffer the events
  which have arrived from upstream.

  The buffer can also be used in cases external sources only send
  events in batches larger than asked for. For example, if you are
  receiving events from an external source that only sends events
  in batches of 1000 in 1000 and the internal demand is smaller than
  that.

  In all of those cases, if the message cannot be sent immediately,
  it is stored and sent whenever there is an opportunity to. The
  size of the buffer is configured via the `:buffer_size` option
  returned by `init/1`. The default value is 10000.

  ## Notifications

  `GenStage` also supports the ability to send notifications to all
  consumers. Those notifications are sent as regular messages outside
  of the demand-driven protocol but respecting the event ordering.
  See `sync_notify/3` and `async_notify/2`.

  Notifications are useful for out-of-band information, for example,
  to notify consumers the producer has sent all events it had to
  process or that a new batch/window of events is starting.

  Note the notification system should not be used for broadcasting
  events, for such, consider using `GenStage.BroadcastDispatcher`.

  ## Callbacks

  `GenStage` is implemented on top of a `GenServer` with two additions.
  Besides exposing all of the `GenServer` callbacks, it also provides
  `handle_demand/2` to be implemented by producers and `handle_events/3`
  to be implemented by consumers, as shown above. Futhermore, all the
  callback responses have been modified to potentially emit events.
  See the callbacks documentation for more information.

  By adding `use GenStage` to your module, Elixir will automatically
  define all callbacks for you except the following:

    * `init/1` - must be implemented to choose between `:producer`, `:consumer` or `:producer_consumer`
    * `handle_demand/2` - must be implemented by `:producer` types
    * `handle_events/3` - must be implemented by `:producer_consumer` and `:consumer` types

  Although this module exposes functions similar to the ones found in
  the `GenServer` API, like `call/3` and `cast/2`, developers can also
  rely directly on GenServer functions such as `GenServer.multi_call/4`
  and `GenServer.abcast/3` if they wish to.

  ### Name Registration

  `GenStage` is bound to the same name registration rules as a `GenServer`.
  Read more about it in the `GenServer` docs.

  ## Message-protocol overview

  This section will describe the message-protocol implemented
  by stages. By documenting these messages, we will allow
  developers to provide their own stage implementations.

  ### Back-pressure

  When data is sent between stages, it is done by a message
  protocol that provides back-pressure. The first step is
  for the consumer to subscribe to the producer. Each
  subscription has a unique reference.

  Once subscribed, the consumer may ask the producer for messages
  for the given subscription. The consumer may demand more items
  whenever it wants to. A consumer must never receive more data
  than it has asked for from any given producer stage.

  A consumer may have multiple producers, where each demand is
  managed invidually. A producer may have multiple consumers,
  where the demand and events are managed and delivered according
  to a `GenStage.Dispatcher` implementation.

  ### Producer messages

  The producer is responsible for sending events to consumers
  based on demand.

    * `{:"$gen_producer", from :: {consumer_pid, subscription_tag}, {:subscribe, options}}` -
      sent by the consumer to the producer to start a new subscription.

      Before sending, the consumer MUST monitor the producer for clean-up
      purposes in case of crashes. The `subscription_tag` is unique to
      identify the subscription. It is typically the subscriber monitoring
      reference although it may be any term.

      Once received, the producer MUST monitor the consumer and properly
      acknoledge or cancel the subscription. The consumer MUST wait until
      the ack message is received before sending demand. However, if the
      subscription reference is known, it must send a `:cancel` message
      to the consumer.

    * `{:"$gen_producer", from :: {pid, subscription_tag}, {:cancel, reason}}` -
      sent by the consumer to cancel a given subscription.

      Once received, the producer MUST send a `:cancel` reply to the
      registered consumer (which may not necessarily be the one received
      in the tuple above). Keep in mind, however, there is no guarantee
      such messages can be delivered in case the producer crashes before.
      If the pair is unknown, the producer MUST send an appropriate cancel
      reply.

    * `{:"$gen_producer", from :: {pid, subscription_tag}, {:ask, count}}` -
      sent by consumers to ask data in a given subscription.

      Once received, the producer MUST send data up to the demand. If the
      pair is unknown, the producer MUST send an appropriate cancel reply.

  ### Consumer messages

  The consumer is responsible for starting the subscription
  and sending demand to producers.

    * `{:"$gen_consumer", from :: {producer_pid, subscription_tag}, :ack}` -
      sent by producers to acknowledge a subscription.

    * `{:"$gen_consumer", from :: {producer_pid, subscription_tag}, {:cancel, reason}}` -
      sent by producers to cancel a given subscription.

      It is used as a confirmation for client cancellations OR
      whenever the producer wants to cancel some upstream demand.

    * `{:"$gen_consumer", from :: {producer_pid, subscription_tag}, [event]}` -
      events sent by producers to consumers.

      `subscription_tag` identifies the subscription. The third argument
      is a non-empty list of events. If the subscription is unknown, the
      events must be ignored and a cancel message sent to the producer.

  """

  defstruct [:mod, :state, :type, :dispatcher_mod, :dispatcher_state, :buffer,
             :buffer_config, events: 0, monitors: %{}, producers: %{}, consumers: %{}]

  @typedoc "The supported stage types."
  @type type :: :producer | :consumer | :producer_consumer

  @typedoc "The supported init options"
  @type options :: []

  @typedoc "The stage reference"
  @type stage :: pid | atom | {:global, term} | {:via, module, term} | {atom, node}

  @doc """
  Invoked when the server is started.

  `start_link/3` (or `start/3`) will block until it returns. `args`
  is the argument term (second argument) passed to `start_link/3`.

  In case of successful start, this callback must return a tuple
  where the first element is the stage type, which is either
  a `:producer`, `:consumer` or `:producer_consumer` if it is
  taking both roles.

  For example:

      def init(args) do
        {:producer, some_state}
      end

  The returned tuple may also contain 3 or 4 elements. The third
  element may be the `:hibernate` atom or a set of options defined
  below.

  Returning `:ignore` will cause `start_link/3` to return `:ignore`
  and the process will exit normally without entering the loop or
  calling `terminate/2`.

  Returning `{:stop, reason}` will cause `start_link/3` to return
  `{:error, reason}` and the process to exit with reason `reason`
  without entering the loop or calling `terminate/2`.

  ## Options

  This callback may return options. Some options are specific to
  the stage type while others are shared across all types.

  ### :producer and :producer_consumer options

    * `:buffer_size` - the size of the buffer to store events
      without demand. Check the "Buffer events" section on the
      module documentation (defaults to 10000 for `:producer`,
      `:infinity` for `:producer_consumer`)
    * `:buffer_keep` - returns if the `:first` or `:last` (default) entries
      should be kept on the buffer in case we exceed the buffer size
    * `:dispatcher` - the dispatcher responsible for handling demands.
      Defaults to `GenStage.DemandDispatch`. May be either an atom or
      a tuple with the dispatcher and the dispatcher options

  ### :consumer and :producer_consumer options

    * `:subscribe_to` - a list of producers to subscribe to. Each element
      represents the producer or a tuple with the producer and the
      subscription options

  """
  @callback init(args :: term) ::
    {type, state} |
    {type, state, options} |
    :ignore |
    {:stop, reason :: any} when state: any

  @doc """
  Invoked on :producer stages.

  Must always be explicitly implemented by `:producer` types.
  It is invoked with the demand from consumers/dispatcher. The
  producer must either store the demand or return the events requested.
  """
  @callback handle_demand(demand :: pos_integer, state :: term) ::
    {:noreply, [event], new_state} |
    {:noreply, [event], new_state, :hibernate} |
    {:stop, reason, new_state} when new_state: term, reason: term, event: term

  @doc """
  Invoked when a consumer subscribes to a producer.

  This callback is invoked in both producers and consumers.

  For consumers, successful subscriptions must return `{:automatic, new_state}`
  or `{:manual, state}`. The default is to return `:automatic`, which means
  the stage implementation will take care of automatically sending demand to
  producers. `:manual` must be used when a special behaviour is desired
  (for example, `DynamicSupervisor` uses `:manual` demand) and demand must
  be sent explicitly with `ask/2`. The manual subscription must be cancelled
  when `handle_cancel/3` is called.

  For producers, successful subscriptions must always return
  `{:automatic, new_state}`, the `:manual` mode is not supported.

  If this callback is not implemented, the default implementation by
  `use GenStage` will return `{:automatic, state}`.
  """
  @callback handle_subscribe(:producer | :consumer, opts :: [options],
                             to_or_from :: GenServer.from, state :: term) ::
    {:automatic | :manual, new_state} |
    {:stop, reason, new_state} when new_state: term, reason: term

  @doc """
  Invoked when a consumer is no longer subscribed to a producer.

  It receives the cancellation reason, the `from` tuple and the state.
  The `cancel_reason` will be a `{:cancel, _}` tuple if the reason for
  cancellation was a `GenStage.cancel/2` call. Any other value means
  the cancellation reason was due to an EXIT.

  If this callback is not implemented, the default implementation by
  `use GenStage` will return `{:noreply, [], state}`.

  Return values are the same as `c:handle_cast/2`.
  """
  @callback handle_cancel({:cancel | :down, reason :: term}, GenServer.from, state :: term) ::
    {:noreply, [event], new_state} |
    {:noreply, [event], new_state, :hibernate} |
    {:stop, reason, new_state} when event: term, new_state: term, reason: term

  @doc """
  Invoked on :producer_consumer and :consumer stages to handle events.

  Must always be explicitly implemented by such types.

  Return values are the same as `c:handle_cast/2`.
  """
  @callback handle_events([event], GenServer.from, state :: term) ::
    {:noreply, [event], new_state} |
    {:noreply, [event], new_state, :hibernate} |
    {:stop, reason, new_state} when new_state: term, reason: term, event: term

  @doc """
  Invoked to handle synchronous `call/3` messages. `call/3` will block until a
  reply is received (unless the call times out or nodes are disconnected).

  `request` is the request message sent by a `call/3`, `from` is a 2-tuple
  containing the caller's PID and a term that uniquely identifies the call, and
  `state` is the current state of the `GenStage`.

  Returning `{:reply, reply, [events], new_state}` sends the response `reply`
  to the caller after events are dispatched (or buffered) and continues the
  loop with new state `new_state`.  In case you want to deliver the reply before
  the processing events, use `GenStage.reply/2` and return `{:noreply, [event],
  state}` (see below).

  Returning `{:noreply, [event], new_state}` does not send a response to the
  caller and processes the given events before continuing the loop with new
  state `new_state`. The response must be sent with `reply/2`.

  Hibernating is also supported as an atom to be returned from either
  `:reply` and `:noreply` tuples.

  Returning `{:stop, reason, reply, new_state}` stops the loop and `terminate/2`
  is called with reason `reason` and state `new_state`. Then the `reply` is sent
  as the response to call and the process exits with reason `reason`.

  Returning `{:stop, reason, new_state}` is similar to
  `{:stop, reason, reply, new_state}` except a reply is not sent.

  If this callback is not implemented, the default implementation by
  `use GenStage` will return `{:stop, {:bad_call, request}, state}`.
  """
  @callback handle_call(request :: term, GenServer.from, state :: term) ::
    {:reply, reply, [event], new_state} |
    {:reply, reply, [event], new_state, :hibernate} |
    {:noreply, [event], new_state} |
    {:noreply, [event], new_state, :hibernate} |
    {:stop, reason, reply, new_state} |
    {:stop, reason, new_state} when reply: term, new_state: term, reason: term, event: term

  @doc """
  Invoked to handle asynchronous `cast/2` messages.

  `request` is the request message sent by a `cast/2` and `state` is the current
  state of the `GenStage`.

  Returning `{:noreply, [event], new_state}` dispatches the events and continues
  the loop with new state `new_state`.

  Returning `{:noreply, [event], new_state, :hibernate}` is similar to
  `{:noreply, new_state}` except the process is hibernated before continuing the
  loop.

  Returning `{:stop, reason, new_state}` stops the loop and `terminate/2` is
  called with the reason `reason` and state `new_state`. The process exits with
  reason `reason`.

  If this callback is not implemented, the default implementation by
  `use GenStage` will return `{:stop, {:bad_cast, request}, state}`.
  """
  @callback handle_cast(request :: term, state :: term) ::
    {:noreply, [event], new_state} |
    {:noreply, [event], new_state, :hibernate} |
    {:stop, reason :: term, new_state} when new_state: term, event: term

  @doc """
  Invoked to handle all other messages.

  `msg` is the message and `state` is the current state of the `GenStage`. When
  a timeout occurs the message is `:timeout`.

  If this callback is not implemented, the default implementation by
  `use GenStage` will return `{:noreply, [], state}`.

  Return values are the same as `c:handle_cast/2`.
  """
  @callback handle_info(msg :: term, state :: term) ::
    {:noreply, [event], new_state} |
    {:noreply, [event], new_state, :hibernate} |
    {:stop, reason :: term, new_state} when new_state: term, event: term

  @doc """
  The same as `c:GenServer.terminate/2`.
  """
  @callback terminate(reason, state :: term) ::
    term when reason: :normal | :shutdown | {:shutdown, term} | term

  @doc """
  The same as `c:GenServer.code_change/3`.
  """
  @callback code_change(old_vsn, state :: term, extra :: term) ::
    {:ok, new_state :: term} |
    {:error, reason :: term} when old_vsn: term | {:down, term}

  @doc """
  The same as `c:GenServer.format_status/2`.
  """
  @callback format_status(:normal | :terminate, [pdict :: {term, term} | state :: term, ...]) ::
    status :: term

  @optional_callbacks [handle_demand: 2, handle_events: 3, format_status: 2]

  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      @behaviour GenServer

      @doc false
      def handle_call(msg, _from, state) do
        # We do this to trick Dialyzer to not complain about non-local returns.
        reason = {:bad_call, msg}
        case :erlang.phash2(1, 1) do
          0 -> exit(reason)
          1 -> {:stop, reason, state}
        end
      end

      @doc false
      def handle_info(_msg, state) do
        {:noreply, [], state}
      end

      @doc false
      def handle_cast(msg, state) do
        # We do this to trick Dialyzer to not complain about non-local returns.
        reason = {:bad_cast, msg}
        case :erlang.phash2(1, 1) do
          0 -> exit(reason)
          1 -> {:stop, reason, state}
        end
      end

      @doc false
      def handle_subscribe(_kind, _opts, _from, state) do
        {:automatic, state}
      end

      @doc false
      def handle_cancel(_reason, _from, state) do
        {:noreply, [], state}
      end

      @doc false
      def terminate(_reason, _state) do
        :ok
      end

      @doc false
      def code_change(_old, state, _extra) do
        {:ok, state}
      end

      defoverridable [handle_call: 3, handle_info: 2, handle_subscribe: 4,
                      handle_cancel: 3, handle_cast: 2, terminate: 2, code_change: 3]
    end
  end

  @doc """
  Starts a `GenStage` process linked to the current process.

  This is often used to start the `GenStage` as part of a supervision tree.

  Once the server is started, the `init/1` function of the given `module` is
  called with `args` as its arguments to initialize the stage. To ensure a
  synchronized start-up procedure, this function does not return until `init/1`
  has returned.

  Note that a `GenStage` started with `start_link/3` is linked to the
  parent process and will exit in case of crashes from the parent. The GenStage
  will also exit due to the `:normal` reasons in case it is configured to trap
  exits in the `init/1` callback.

  ## Options

    * `:name` - used for name registration as described in the "Name
      registration" section of the module documentation

    * `:timeout` - if present, the server is allowed to spend the given amount of
      milliseconds initializing or it will be terminated and the start function
      will return `{:error, :timeout}`

    * `:debug` - if present, the corresponding function in the [`:sys`
      module](http://www.erlang.org/doc/man/sys.html) is invoked

    * `:spawn_opt` - if present, its value is passed as options to the
      underlying process as in `Process.spawn/4`

  ## Return values

  If the server is successfully created and initialized, this function returns
  `{:ok, pid}`, where `pid` is the pid of the server. If a process with the
  specified server name already exists, this function returns
  `{:error, {:already_started, pid}}` with the pid of that process.

  If the `init/1` callback fails with `reason`, this function returns
  `{:error, reason}`. Otherwise, if it returns `{:stop, reason}`
  or `:ignore`, the process is terminated and this function returns
  `{:error, reason}` or `:ignore`, respectively.
  """
  @spec start_link(module, any, options) :: GenServer.on_start
  def start_link(module, args, options \\ []) when is_atom(module) and is_list(options) do
    GenServer.start_link(__MODULE__, {module, args}, options)
  end

  @doc """
  Starts a `GenStage` process without links (outside of a supervision tree).

  See `start_link/3` for more information.
  """
  @spec start(module, any, options) :: GenServer.on_start
  def start(module, args, options \\ []) when is_atom(module) and is_list(options) do
    GenServer.start(__MODULE__, {module, args}, options)
  end

  @doc """
  Asks the producer to send a notification to all consumers synchronously.

  This call is synchronous and will return after the producer has either
  sent the notification to all consumers or placed it in a buffer. In
  other words, it guarantees the producer has handled the message but not
  that the consumers have received it.

  The given message will be delivered in the format `{ref, msg}`, where
  `ref` is the subscription reference and `msg` is the message given below.

  This function will return `:ok` as long as the notification request is
  sent. It may return `{:error, :not_a_producer}` in case the stage is not
  a producer.
  """
  @spec sync_notify(stage, msg :: term(), timeout) :: :ok | {:error, :not_a_producer}
  def sync_notify(stage, msg, timeout \\ 5_000) do
    call(stage, {:"$notify", msg}, timeout)
  end

  @doc """
  Asks the consumer to subscribe to the given producer asynchronously.

  This call returns `:ok` regardless if the notification has been
  received by the producer or sent. It is typically called from
  the producer stage itself.
  """
  @spec async_notify(stage, msg :: term()) :: :ok
  def async_notify(stage, msg) do
    cast(stage, {:"$notify", msg})
  end

  @doc """
  Asks the consumer to subscribe to the given producer synchronously.

  This call is synchronous and will return after the called consumer
  sends the subscribe message to the producer. It does not, however,
  wait for the subscription confirmation. Therefore this function
  will return before `handle_subscribe` is called in the consumer.
  In other words, it guarantees the message was sent, but it does not
  guarantee a subscription has effectively been established.

  This function will return `{:ok, ref}` as long as the subscription
  message is sent. It may return `{:error, :not_a_consumer}` in case
  the stage is not a consumer.

  ## Options

    * `:cancel` - `:permanent` (default) or `:temporary`. When permanent,
      the consumer exits when the producer cancels or exits. In case
      of exits, the same reason is used to exit the consumer. In case of
      cancellations, the reason is wrapped in a `:cancel` tuple.
    * `:min_demand` - the minimum demand for this subscription
    * `:max_demand` - the maximum demand for this subscription

  All other options are sent as is to the producer stage.
  """
  @spec sync_subscribe(stage, opts :: keyword(), timeout) ::
        {:ok, reference()} | {:error, :not_a_consumer} | {:error, {:bad_opts, String.t}}
  def sync_subscribe(stage, opts, timeout \\ 5_000) do
    {to, opts} =
      Keyword.pop_lazy(opts, :to, fn ->
        raise ArgumentError, "expected :to argument in subscribe"
      end)
    call(stage, {:"$subscribe", to, opts}, timeout)
  end

  @doc """
  Asks the consumer to subscribe to the given producer asynchronously.

  This call returns `:ok` regardless if the subscription
  effectively happened or not. It is typically called from
  a stage own's `init/1` callback.

  ## Options

    * `:cancel` - `:permanent` (default) or `:temporary`. When permanent,
      the consumer exits when the producer cancels or exits. In case
      of exits, the same reason is used to exit the consumer. In case of
      cancellations, the reason is wrapped in a `:cancel` tuple.
    * `:min_demand` - the minimum demand for this subscription
    * `:max_demand` - the maximum demand for this subscription

  All other options are sent as is to the producer stage.

  ## Examples

      def init(producer) do
        GenStage.async_subscribe(self(), to: producer, min_demand: 800, max_demand: 1000)
        {:consumer, []}
      end

  """
  @spec async_subscribe(stage, opts :: keyword()) :: :ok
  def async_subscribe(stage, opts) do
    {to, opts} =
      Keyword.pop_lazy(opts, :to, fn ->
        raise ArgumentError, "expected :to argument in subscribe"
      end)
    cast(stage, {:"$subscribe", to, opts})
  end

  @doc """
  Asks the given demand to the producer.

  This is an asynchronous request typically used
  by consumers in `:manual` demand mode.

  It accepts the same options as `Process.send/3`.
  """
  def ask({pid, ref}, demand, opts \\ []) when is_integer(demand) and demand > 0 do
    Process.send(pid, {:"$gen_producer", {self(), ref}, {:ask, demand}}, opts)
    :ok
  end

  @doc """
  Cancels the given subscription on the producer.

  Once the producer receives the request, a confirmation
  may be forwarded to the consumer (although there is no
  guarantee as the producer may crash for unrelated reasons
  before). This is an asynchronous request.

  It accepts the same options as `Process.send/3`.
  """
  def cancel({pid, ref}, reason, opts \\ []) do
    Process.send(pid, {:"$gen_producer", {self(), ref}, {:cancel, reason}}, opts)
    :ok
  end

  @compile {:inline, send_noconnect: 2, ask: 3, cancel: 3}

  defp send_noconnect(pid, msg) do
    Process.send(pid, msg, [:noconnect])
  end

  @doc """
  Makes a synchronous call to the `stage` and waits for its reply.

  The client sends the given `request` to the server and waits until a reply
  arrives or a timeout occurs. `handle_call/3` will be called on the stage
  to handle the request.

  `stage` can be any of the values described in the "Name registration"
  section of the documentation for this module.

  ## Timeouts

  `timeout` is an integer greater than zero which specifies how many
  milliseconds to wait for a reply, or the atom `:infinity` to wait
  indefinitely. The default value is `5000`. If no reply is received within
  the specified time, the function call fails and the caller exits. If the
  caller catches the failure and continues running, and the stage is just late
  with the reply, it may arrive at any time later into the caller's message
  queue. The caller must in this case be prepared for this and discard any such
  garbage messages that are two-element tuples with a reference as the first
  element.
  """
  @spec call(stage, term, timeout) :: term
  def call(stage, request, timeout \\ 5000) do
    GenServer.call(stage, request, timeout)
  end

  @doc """
  Sends an asynchronous request to the `stage`.

  This function always returns `:ok` regardless of whether
  the destination `stage` (or node) exists. Therefore it
  is unknown whether the destination `stage` successfully
  handled the message.

  `handle_cast/2` will be called on the stage to handle
  the request. In case the `stage` is on a node which is
  not yet connected to the caller one, the call is going to
  block until a connection happens.
  """
  @spec cast(stage, term) :: :ok
  def cast(stage, request) do
    GenServer.cast(stage, request)
  end

  @doc """
  Replies to a client.

  This function can be used to explicitely send a reply to a client that
  called `call/3` when the reply cannot be specified in the return value
  of `handle_call/3`.

  `client` must be the `from` argument (the second argument) accepted by
  `handle_call/3` callbacks. `reply` is an arbitrary term which will be given
  back to the client as the return value of the call.

  Note that `reply/2` can be called from any process, not just the GenServer
  that originally received the call (as long as that GenServer communicated the
  `from` argument somehow).

  This function always returns `:ok`.

  ## Examples

      def handle_call(:reply_in_one_second, from, state) do
        Process.send_after(self(), {:reply, from}, 1_000)
        {:noreply, [], state}
      end

      def handle_info({:reply, from}, state) do
        GenStage.reply(from, :one_second_has_passed)
      end

  """
  @spec reply(GenServer.from, term) :: :ok
  def reply(client, reply)

  def reply({to, tag}, reply) when is_pid(to) do
    try do
      send(to, {tag, reply})
      :ok
    catch
      _, _ -> :ok
    end
  end

  @doc """
  Stops the stage with the given `reason`.

  The `terminate/2` callback of the given `stage` will be invoked before
  exiting. This function returns `:ok` if the server terminates with the
  given reason; if it terminates with another reason, the call exits.

  This function keeps OTP semantics regarding error reporting.
  If the reason is any other than `:normal`, `:shutdown` or
  `{:shutdown, _}`, an error report is logged.
  """
  @spec stop(stage, reason :: term, timeout) :: :ok
  def stop(stage, reason \\ :normal, timeout \\ :infinity) do
    :gen.stop(stage, reason, timeout)
  end

  @doc """
  Starts a producer stage from an enumerable (or stream).

  This function will start a stage linked to the current process
  that will take items from the enumerable when there is demand.
  Since streams are enumerables, we can also pass streams as
  arguments (in fact, streams are the most common argument to
  this function).

  When the enumerable finishes or halts, a notification is sent
  to all consumers in the format of
  `{subscription_tag, {:producer, :halted | :done}}`. If the stage
  is meant to be temporary instead of long running, we recommend
  setting the `:consumers` option to `:permanent` so the stage
  exits if any of the consumers exits.

  Keep in mind that streams that require the use of the process
  inbox to work most likely won't behave as expected with this
  function since the mailbox is controlled by the stage process
  itself.

  ## Options

    * `:link` - when false, does not link the stage to the current
      process. Defaults to `true`

    * `:consumers` - when `:permanent`, the stage exits when a
      consumer exits. Defaults to `:temporary`

    * `:dispatcher` - the dispatcher responsible for handling demands.
      Defaults to `GenStage.DemandDispatch`. May be either an atom or
      a tuple with the dispatcher and the dispatcher options

  All other options that would be given for `start_link/3` are
  also accepted.
  """
  @spec from_enumerable(Enumerable.t, Keyword.t) :: GenServer.on_start
  def from_enumerable(stream, opts \\ []) do
    case Keyword.pop(opts, :link, true) do
      {true, opts} -> start_link(GenStage.Streamer, {stream, opts}, opts)
      {false, opts} -> start(GenStage.Streamer, {stream, opts}, opts)
    end
  end

  @doc """
  Creates a stream that subscribes to the given producers
  and emits the appropriate messages.

  It expects a list of producers to subscribe to. Each element
  represents the producer or a tuple with the producer and the
  subscription options as defined in `async_subscribe/2`.

  `GenStage.stream/1` will "hijack" the inbox of the process
  enumerating the stream to subscribe and receive messages
  from producers. However it guarantees it won't remove or
  leave unwanted messages in the mailbox after enumeration
  except if one of the producers come from a remote node.
  For more information, read the "Known limitations" section
  below.

  ## Known limitations

  ### from_enumerable

  This module also provides a function called `from_enumerable/2`
  which receives an enumerable (like a stream) and creates a stage
  that emits data from the enumerable.

  Given both `GenStage.from_enumerable/2` and `GenStage.stream/1`
  require the process inbox to send and receive messages, it is
  impossible to run a `stream/1` inside a `from_enumerable/2` as
  the `stream/1` will never receive the messages it expects.

  ### Remote nodes

  While it is possible to stream messages from remote nodes
  such should be done with care. In particular, in case of
  disconnections, there is a chance the producer will send
  messages after the consumer receives its DOWN messages and
  those will remain in the process inbox, violating the
  common scenario where `GenStage.stream/1` does not pollute
  the caller inbox. In such cases, it is recommended to
  consume such streams from a separate process which will be
  discarded after the stream is consumed.
  """
  @spec stream([stage | {stage, Keyword.t}]) :: Enumerable.t
  def stream(subscriptions) when is_list(subscriptions) do
    subscriptions = Enum.map(subscriptions, &stream_validate_opts/1)
    Stream.resource(fn -> init_stream(subscriptions) end,
                    &consume_stream/1,
                    &close_stream/1)
  end

  def stream(subscriptions) do
    raise ArgumentError, "GenStage.stream/1 expects a list of subscriptions, got: #{inspect subscriptions}"
  end

  defp stream_validate_opts({to, full_opts}) when is_list(full_opts) do
    with {:ok, cancel, opts} <- validate_in(full_opts, :cancel, :permanent, [:temporary, :permanent]),
         {:ok, max, opts} <- validate_integer(opts, :max_demand, 1000, 1, :infinity, false),
         {:ok, min, opts} <- validate_integer(opts, :min_demand, div(max, 2), 0, max - 1, false) do
      {to, cancel, min, max, opts, full_opts}
    else
      {:error, message} ->
        raise ArgumentError, "invalid options for #{inspect to} producer (#{message})"
    end
  end

  defp stream_validate_opts(to) do
    stream_validate_opts({to, []})
  end

  defp init_monitor(parent, subscriptions) do
    parent_ref = Process.monitor(parent)

    receive do
      {:DOWN, ^parent_ref, _, _, reason} ->
        exit(reason)
      {^parent, monitor_ref} ->
        subscriptions = subscriptions_monitor(parent, monitor_ref, subscriptions)
        send(parent, {monitor_ref, {:subscriptions, subscriptions}})
        loop_monitor(parent, parent_ref, monitor_ref, Map.keys(subscriptions))
    end
  end

  defp subscriptions_monitor(parent, monitor_ref, subscriptions) do
    Enum.reduce(subscriptions, %{}, fn {to, cancel, min, max, opts, full_opts}, acc ->
      producer_pid = GenServer.whereis(to)

      cond do
        producer_pid != nil ->
          inner_ref = Process.monitor(producer_pid)
          send_noconnect(producer_pid, {:"$gen_producer", {parent, {monitor_ref, inner_ref}}, {:subscribe, opts}})
          Map.put(acc, inner_ref, {:ack, producer_pid, cancel, min, max, full_opts})
        cancel == :temporary ->
          acc
        cancel == :permanent ->
          exit({:noproc, {GenStage, :init_stream, [subscriptions]}})
      end
    end)
  end

  defp loop_monitor(parent, parent_ref, monitor_ref, keys) do
    receive do
      {:DOWN, ^parent_ref, _, _, reason} ->
        exit(reason)
      {:DOWN, ref, _, _, reason} ->
        if ref in keys do
          send(parent, {{monitor_ref, ref}, {:down, reason}})
        end
        loop_monitor(parent, parent_ref, monitor_ref, keys -- [ref])
    end
  end

  defp init_stream(subscriptions) do
    parent = self()

    {monitor_pid, monitor_ref} =
      spawn_monitor(fn -> init_monitor(parent, subscriptions) end)
    send(monitor_pid, {parent, monitor_ref})

    receive do
      {:DOWN, ^monitor_ref, _, _, reason} ->
        exit(reason)
      {^monitor_ref, {:subscriptions, subscriptions}} ->
        {:receive, monitor_ref, subscriptions}
    end
  end

  defp consume_stream({:receive, monitor_ref, subscriptions}) do
    receive_stream(monitor_ref, subscriptions)
  end
  defp consume_stream({:ask, from, ask, batches, monitor_ref, subscriptions}) do
    ask > 0 and ask(from, ask, [:noconnect])
    deliver_stream(batches, from, monitor_ref, subscriptions)
  end

  defp close_stream({:receive, monitor_ref, subscriptions}) do
    request_to_cancel_stream(monitor_ref, subscriptions)
  end
  defp close_stream({:ask, _, _, _, monitor_ref, subscriptions}) do
    request_to_cancel_stream(monitor_ref, subscriptions)
  end
  defp close_stream({:exit, reason, monitor_ref, subscriptions}) do
    request_to_cancel_stream(monitor_ref, subscriptions)
    exit({reason, {GenStage, :close_stream, [subscriptions]}})
  end

  defp receive_stream(monitor_ref, subscriptions) when map_size(subscriptions) == 0 do
    {:halt, {:receive, monitor_ref, subscriptions}}
  end
  defp receive_stream(monitor_ref, subscriptions) do
    receive do
      # TODO: Support redirects
      {:"$gen_consumer", {producer_pid, {^monitor_ref, inner_ref} = ref}, :ack} ->
        case subscriptions do
          %{^inner_ref => {:ack, producer_pid, cancel, min, max, _opts}} ->
            ask({producer_pid, ref}, max, [:noconnect])
            subscribed = {:subscribed, producer_pid, cancel, min, max, max}
            receive_stream(monitor_ref, Map.put(subscriptions, inner_ref, subscribed))
          %{^inner_ref => {:cancel, _}} ->
            # We received this message before the cancellation was processed
            receive_stream(monitor_ref, subscriptions)
          _ ->
            # Cancel if messages are out of order or unknown
            send_noconnect(producer_pid, {:"$gen_producer", {self(), ref}, {:cancel, :unknown_subscription}})
            receive_stream(monitor_ref, Map.delete(subscriptions, inner_ref))
        end

      {:"$gen_consumer", {producer_pid, {^monitor_ref, inner_ref} = ref}, events} when is_list(events) ->
        case subscriptions do
          %{^inner_ref => {:subscribed, producer_pid, cancel, min, max, demand}} ->
            from = {producer_pid, ref}
            {demand, batches} = split_batches(events, from, min, max, demand, demand, [])
            subscribed = {:subscribed, producer_pid, cancel, min, max, demand}
            deliver_stream(batches, from, monitor_ref, Map.put(subscriptions, inner_ref, subscribed))
          %{^inner_ref => {:cancel, _}} ->
            # We received this message before the cancellation was processed
            receive_stream(monitor_ref, subscriptions)
          _ ->
            # Cancel if messages are out of order or unknown
            send_noconnect(producer_pid, {:"$gen_producer", {self(), ref}, {:cancel, :unknown_subscription}})
            receive_stream(monitor_ref, Map.delete(subscriptions, inner_ref))
        end

      {:"$gen_consumer", {_, {^monitor_ref, inner_ref}}, {:cancel, _} = reason} ->
        cancel_stream(inner_ref, reason, monitor_ref, subscriptions)

      {{^monitor_ref, inner_ref}, {:down, reason}} ->
        cancel_stream(inner_ref, reason, monitor_ref, subscriptions)

      {{^monitor_ref, inner_ref}, {:producer, status}}
          when is_reference(inner_ref) and status in [:halted, :done] ->
        case subscriptions do
          %{^inner_ref => tuple} ->
            subscriptions = request_to_cancel_stream(inner_ref, tuple, monitor_ref, subscriptions)
            receive_stream(monitor_ref, subscriptions)
          %{} ->
            receive_stream(monitor_ref, subscriptions)
        end
    end
  end

  defp deliver_stream([], _from, monitor_ref, subscriptions) do
    receive_stream(monitor_ref, subscriptions)
  end
  defp deliver_stream([{events, ask} | batches], from, monitor_ref, subscriptions) do
    {events, {:ask, from, ask, batches, monitor_ref, subscriptions}}
  end

  defp request_to_cancel_stream(monitor_ref, subscriptions) do
    subscriptions =
      Enum.reduce(subscriptions, subscriptions, fn {inner_ref, tuple}, acc ->
        request_to_cancel_stream(inner_ref, tuple, monitor_ref, acc)
      end)
    receive_stream(monitor_ref, subscriptions)
  end

  defp request_to_cancel_stream(_ref, {:cancel, _}, _monitor_ref, subscriptions) do
    subscriptions
  end
  defp request_to_cancel_stream(inner_ref, tuple, monitor_ref, subscriptions) do
    process_pid = elem(tuple, 1)
    cancel({process_pid, {monitor_ref, inner_ref}}, :normal, [:noconnect])
    Map.put(subscriptions, inner_ref, {:cancel, process_pid})
  end

  defp cancel_stream(inner_ref, reason, monitor_ref, subscriptions) do
    case subscriptions do
      %{^inner_ref => {_, _, :permanent, _, _, _}} ->
        Process.demonitor(inner_ref, [:flush])
        {:halt, {:exit, reason, monitor_ref, Map.delete(subscriptions, inner_ref)}}
      %{^inner_ref => _} ->
        Process.demonitor(inner_ref, [:flush])
        receive_stream(monitor_ref, Map.delete(subscriptions, inner_ref))
      %{} ->
        receive_stream(monitor_ref, subscriptions)
    end
  end

  ## Callbacks

  @doc false
  def init({mod, args}) do
    case mod.init(args) do
      {:producer, state} ->
        init_producer(mod, [], state)
      {:producer, state, opts} when is_list(opts) ->
        init_producer(mod, opts, state)
      {:producer_consumer, state} ->
        init_producer_consumer(mod, [], state)
      {:producer_consumer, state, opts} when is_list(opts) ->
        init_producer_consumer(mod, opts, state)
      {:consumer, state} ->
        init_consumer(mod, [], state)
      {:consumer, state, opts} when is_list(opts) ->
        init_consumer(mod, opts, state)
      {:stop, _} = stop ->
        stop
      :ignore ->
        :ignore
      other ->
        {:stop, {:bad_return_value, other}}
    end
  end

  defp init_producer(mod, opts, state) do
    with {:ok, dispatcher_mod, dispatcher_state, opts} <- validate_dispatcher(opts),
         {:ok, buffer_size, opts} <- validate_integer(opts, :buffer_size, 10000, 0, :infinity, true),
         {:ok, buffer_keep, opts} <- validate_in(opts, :buffer_keep, :last, [:first, :last]),
         :ok <- validate_no_opts(opts) do
      {:ok, %GenStage{mod: mod, state: state, type: :producer,
                      buffer: {:queue.new, 0, init_wheel(buffer_size)},
                      buffer_config: {buffer_size, buffer_keep},
                      dispatcher_mod: dispatcher_mod, dispatcher_state: dispatcher_state}}
    else
      {:error, message} -> {:stop, {:bad_opts, message}}
    end
  end

  defp validate_dispatcher(opts) do
    case Keyword.pop(opts, :dispatcher, GenStage.DemandDispatcher) do
      {dispatcher, opts} when is_atom(dispatcher) ->
        {:ok, dispatcher_state} = dispatcher.init([])
        {:ok, dispatcher, dispatcher_state, opts}
      {{dispatcher, dispatcher_opts}, opts} when is_atom(dispatcher) and is_list(dispatcher_opts) ->
        {:ok, dispatcher_state} = dispatcher.init(dispatcher_opts)
        {:ok, dispatcher, dispatcher_state, opts}
      {other, _opts} ->
        {:error, "expected :dispatcher to be an atom or a {atom, list}, got: #{inspect other}"}
    end
  end

  defp init_producer_consumer(mod, opts, state) do
    {producers, opts} = Keyword.pop(opts, :subscribe_to, [])

    with {:ok, dispatcher_mod, dispatcher_state, opts} <- validate_dispatcher(opts),
         {:ok, buffer_size, opts} <- validate_integer(opts, :buffer_size, :infinity, 0, :infinity, true),
         {:ok, buffer_keep, opts} <- validate_in(opts, :buffer_keep, :last, [:first, :last]),
         :ok <- validate_no_opts(opts) do
      stage = %GenStage{mod: mod, state: state, type: :producer_consumer,
                        buffer: {:queue.new, 0, init_wheel(buffer_size)},
                        buffer_config: {buffer_size, buffer_keep},
                        dispatcher_mod: dispatcher_mod, dispatcher_state: dispatcher_state}
      consumer_init_subscribe(producers, stage)
    else
      {:error, message} -> {:stop, {:bad_opts, message}}
    end
  end

  defp init_consumer(mod, opts, state) do
    {producers, opts} = Keyword.pop(opts, :subscribe_to, [])

    with :ok <- validate_no_opts(opts) do
      stage = %GenStage{mod: mod, state: state, type: :consumer}
      consumer_init_subscribe(producers, stage)
    else
      {:error, message} -> {:stop, {:bad_opts, message}}
    end
  end

  defp validate_in(opts, key, default, values) do
    {value, opts} = Keyword.pop(opts, key, default)

    if value in values do
      {:ok, value, opts}
    else
      {:error, "expected #{inspect key} to be one of #{inspect values}, got: #{inspect value}"}
    end
  end

  defp validate_integer(opts, key, default, min, max, infinity?) do
    {value, opts} = Keyword.pop(opts, key, default)

    cond do
      value == :infinity and infinity? ->
        {:ok, value, opts}
      not is_integer(value) ->
        {:error, "expected #{inspect key} to be an integer, got: #{inspect value}"}
      value < min ->
        {:error, "expected #{inspect key} to be equal to or greater than #{min}, got: #{inspect value}"}
      value > max ->
        {:error, "expected #{inspect key} to be equal to or less than #{max}, got: #{inspect value}"}
      true ->
        {:ok, value, opts}
    end
  end

  defp validate_no_opts(opts) do
    if opts == [] do
      :ok
    else
      {:error, "unknown options #{inspect opts}"}
    end
  end

  @doc false
  def handle_call({:"$notify", msg}, _from, stage) do
    producer_notify(msg, stage)
  end

  def handle_call({:"$subscribe", to, opts}, _from, stage) do
    consumer_subscribe(to, opts, stage)
  end

  def handle_call(msg, from, %{mod: mod, state: state} = stage) do
    case mod.handle_call(msg, from, state) do
      {:reply, reply, events, state} when is_list(events) ->
        stage = dispatch_events(events, stage)
        {:reply, reply, %{stage | state: state}}
      {:reply, reply, events, state, :hibernate} when is_list(events) ->
        stage = dispatch_events(events, stage)
        {:reply, reply, %{stage | state: state}, :hibernate}
      {:stop, reason, reply, state} ->
        {:stop, reason, reply, %{stage | state: state}}
      return ->
        handle_noreply_callback(return, stage)
    end
  end

  @doc false
  def handle_cast({:"$notify", msg}, stage) do
    {:reply, _, stage} = producer_notify(msg, stage)
    {:noreply, stage}
  end

  def handle_cast({:"$subscribe", to, opts}, stage) do
    case consumer_subscribe(to, opts, stage) do
      {:reply, _, stage}        -> {:noreply, stage}
      {:stop, reason, _, stage} -> {:stop, reason, stage}
    end
  end

  def handle_cast(msg, %{state: state} = stage) do
    noreply_callback(:handle_cast, [msg, state], stage)
  end

  @doc false
  def handle_info({:DOWN, ref, _, _, reason} = msg,
                  %{producers: producers, monitors: monitors, state: state} = stage) do
    case producers do
      %{^ref => _} ->
        consumer_cancel(ref, :down, reason, stage)
      %{} ->
        case monitors do
          %{^ref => {_, cancel, _, _, _}} ->
            consumer_no_ack(cancel, reason, %{stage | monitors: Map.delete(monitors, ref)})
          %{^ref => consumer_ref} when is_reference(consumer_ref) ->
            producer_cancel(consumer_ref, :down, reason, stage)
          %{} ->
            noreply_callback(:handle_info, [msg, state], stage)
        end
    end
  end

  ## Producer messages

  def handle_info({:"$gen_producer", _, _} = msg, %{type: :consumer} = stage) do
    :error_logger.error_msg('GenStage consumer ~p received $gen_producer message: ~p~n', [name(), msg])
    {:noreply, stage}
  end

  def handle_info({:"$gen_producer", {consumer_pid, ref} = from, {:subscribe, opts}},
                  %{consumers: consumers} = stage) do
    case consumers do
      %{^ref => _} ->
        :error_logger.error_msg('GenStage producer ~p received duplicated subscription from: ~p~n', [name(), from])
        send_noconnect(consumer_pid, {:"$gen_consumer", {self(), ref}, {:cancel, :duplicated_subscription}})
        {:noreply, stage}
      %{} ->
        mon_ref = Process.monitor(consumer_pid)
        stage = put_in stage.monitors[mon_ref], ref
        stage = put_in stage.consumers[ref], {consumer_pid, mon_ref}
        send_noconnect(consumer_pid, {:"$gen_consumer", {self(), ref}, :ack})
        producer_subscribe(opts, from, stage)
    end
  end

  def handle_info({:"$gen_producer", {consumer_pid, ref} = from, {:ask, counter}},
                  %{consumers: consumers} = stage) when is_integer(counter) do
    case consumers do
      %{^ref => _} ->
        %{dispatcher_state: dispatcher_state} = stage
        dispatcher_callback(:ask, [counter, from, dispatcher_state], stage)
      %{} ->
        send_noconnect(consumer_pid, {:"$gen_consumer", {self(), ref}, {:cancel, :unknown_subscription}})
        {:noreply, stage}
    end
  end

  def handle_info({:"$gen_producer", {_, ref}, {:cancel, reason}}, stage) do
    producer_cancel(ref, :cancel, reason, stage)
  end

  ## Consumer messages

  def handle_info({:"$gen_consumer", _, _} = msg, %{type: :producer} = stage) do
    :error_logger.error_msg('GenStage producer ~p received $gen_consumer message: ~p~n', [name(), msg])
    {:noreply, stage}
  end

  def handle_info({:"$gen_consumer", {producer_pid, ref}, events},
                  %{type: :producer_consumer, events: demand_or_queue, producers: producers} = stage) when is_list(events) do
    case producers do
      %{^ref => _entry} ->
        {events, demand_or_queue} =
          case demand_or_queue do
            demand when is_integer(demand) ->
              split_pc_events(events, ref, demand, [])
            queue ->
              {[], put_pc_events(events, ref, queue)}
          end
        send_pc_events(events, ref, %{stage | events: demand_or_queue})
      _ ->
        send_noconnect(producer_pid, {:"$gen_producer", {self(), ref}, {:cancel, :unknown_subscription}})
        {:noreply, stage}
    end
  end

  def handle_info({:"$gen_consumer", {producer_pid, ref} = from, events},
                  %{type: :consumer, producers: producers, mod: mod, state: state} = stage) when is_list(events) do
    case producers do
      %{^ref => entry} ->
        {producer_pid, _, _} = entry
        {batches, stage} = consumer_receive(from, entry, events, stage)
        consumer_dispatch(batches, from, mod, state, stage, false)
      _ ->
        send_noconnect(producer_pid, {:"$gen_producer", {self(), ref}, {:cancel, :unknown_subscription}})
        {:noreply, stage}
    end
  end

  # TODO: Support redirects
  def handle_info({:"$gen_consumer", {producer_pid, ref}, :ack},
                  %{monitors: monitors, mod: mod, state: state} = stage) do
    case Map.pop(monitors, ref) do
      {{producer_pid, cancel, min, max, opts}, monitors} ->
        to = {producer_pid, ref}
        stage = %{stage | monitors: monitors}

        case apply(mod, :handle_subscribe, [:producer, opts, to, state]) do
          {:automatic, state} ->
            ask(to, max, [:noconnect])
            stage = put_in stage.producers[ref], {producer_pid, cancel, {max, min, max}}
            {:noreply, %{stage | state: state}}
          {:manual, state} ->
            stage = put_in stage.producers[ref], {producer_pid, cancel, :manual}
            {:noreply, %{stage | state: state}}
          {:stop, reason, state} ->
            {:stop, reason, %{stage | state: state}}
          other ->
            {:stop, {:bad_return_value, other}, stage}
        end
      {nil, _monitors} ->
        send_noconnect(producer_pid, {:"$gen_producer", {self(), ref}, {:cancel, :unknown_subscription}})
        {:noreply, stage}
    end
  end

  def handle_info({:"$gen_consumer", {_, ref}, {:cancel, reason}},
                  %{monitors: monitors} = stage) do
    case Map.pop(monitors, ref) do
      {{_, cancel, _, _, _}, monitors} ->
        consumer_no_ack(cancel, reason, %{stage | monitors: monitors})
      {nil, _monitors} ->
        consumer_cancel(ref, :cancel, reason, stage)
    end
  end

  ## Catch-all messages

  def handle_info(msg, %{state: state} = stage) do
    noreply_callback(:handle_info, [msg, state], stage)
  end

  @doc false
  def terminate(reason, %{mod: mod, state: state}) do
    mod.terminate(reason, state)
  end

  @doc false
  def code_change(old_vsn, %{mod: mod, state: state} = stage, extra) do
    case mod.code_change(old_vsn, state, extra) do
      {:ok, state} -> {:ok, %{stage | state: state}}
      other -> other
    end
  end

  @doc false
  def format_status(opt, [pdict, %{mod: mod, state: state}]) do
    case {function_exported?(mod, :format_status, 2), opt} do
      {true, :normal} ->
        format_status(mod, opt, pdict, state, [data: [{~c(State), state}]])
      {true, :terminate} ->
        format_status(mod, opt, pdict, state, state)
      {false, :normal} ->
        [data: [{~c(State), state}]]
      {false, :terminate} ->
        state
    end
  end

  defp format_status(mod, opt, pdict, state, default) do
    try do
      mod.format_status(opt, [pdict, state])
    catch
      _, _ ->
        default
    end
  end

  ## Shared helpers

  defp noreply_callback(callback, args, %{mod: mod} = stage) do
    handle_noreply_callback apply(mod, callback, args), stage
  end

  defp handle_noreply_callback(return, stage) do
    case return do
      {:noreply, events, state} when is_list(events) ->
        stage = dispatch_events(events, stage)
        {:noreply, %{stage | state: state}}
      {:noreply, events, state, :hibernate} when is_list(events) ->
        stage = dispatch_events(events, stage)
        {:noreply, %{stage | state: state}, :hibernate}
      {:stop, reason, state} ->
        {:stop, reason, %{stage | state: state}}
      other ->
        {:stop, {:bad_return_value, other}, stage}
    end
  end

  defp name() do
    case :erlang.process_info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> self()
    end
  end

  ## Producer helpers

  defp producer_subscribe(opts, from, stage) do
    %{mod: mod, state: state, dispatcher_state: dispatcher_state} = stage

    case apply(mod, :handle_subscribe, [:consumer, opts, from, state]) do
      {:automatic, state} ->
        # Call the dispatcher after since it may generate demand and the
        # main module must know the consumer is subscribed.
        dispatcher_callback(:subscribe, [opts, from, dispatcher_state], %{stage | state: state})
      {:stop, reason, state} ->
        {:stop, reason, %{stage | state: state}}
      other ->
        {:stop, {:bad_return_value, other}, stage}
    end
  end

  defp producer_cancel(ref, kind, reason, stage) do
    %{consumers: consumers, monitors: monitors, state: state} = stage

    case Map.pop(consumers, ref) do
      {nil, _consumers} ->
        {:noreply, stage}
      {{pid, mon_ref}, consumers} ->
        Process.demonitor(mon_ref, [:flush])
        send_noconnect(pid, {:"$gen_consumer", {self(), ref}, {:cancel, reason}})
        stage = %{stage | consumers: consumers, monitors: Map.delete(monitors, mon_ref)}

        case noreply_callback(:handle_cancel, [{kind, reason}, {pid, ref}, state], stage) do
          {:noreply, %{dispatcher_state: dispatcher_state} = stage} ->
            # Call the dispatcher after since it may generate demand and the
            # main module must know the consumer is no longer subscribed.
            dispatcher_callback(:cancel, [{pid, ref}, dispatcher_state], stage)
          {:stop, _, _} = stop ->
            stop
        end
    end
  end

  defp dispatcher_callback(callback, args, %{dispatcher_mod: dispatcher_mod} = stage) do
    {:ok, counter, dispatcher_state} = apply(dispatcher_mod, callback, args)
    stage = %{stage | dispatcher_state: dispatcher_state}

    case take_from_buffer(counter, stage) do
      {:ok, 0, stage} ->
        {:noreply, stage}
      {:ok, counter, stage} when is_integer(counter) and counter > 0 ->
        case stage do
          %{type: :producer_consumer} ->
            handle_demand(counter, stage)
          %{state: state} ->
            noreply_callback(:handle_demand, [counter, state], stage)
        end
    end
  end

  defp handle_demand(counter, %{events: events} = stage) when is_integer(events) do
    {:noreply, %{stage | events: events + counter}}
  end

  defp handle_demand(counter, %{events: events} = stage) do
    take_pc_events(events, counter, stage)
  end

  defp dispatch_events([], stage) do
    stage
  end
  defp dispatch_events(events, %{type: :consumer} = stage) do
    :error_logger.error_msg('GenStage consumer ~p cannot dispatch events (an empty list must be returned): ~p~n', [name(), events])
    stage
  end
  defp dispatch_events(events, %{consumers: consumers} = stage) when map_size(consumers) == 0 do
    buffer_events(events, stage)
  end
  defp dispatch_events(events, stage) do
    %{dispatcher_mod: dispatcher_mod, dispatcher_state: dispatcher_state} = stage
    {:ok, events, dispatcher_state} = dispatcher_mod.dispatch(events, dispatcher_state)
    buffer_events(events, %{stage | dispatcher_state: dispatcher_state})
  end

  defp take_from_buffer(counter, %{buffer: {_, buffer, _}} = stage)
       when counter == 0 when buffer == 0 do
    {:ok, counter, stage}
  end

  defp take_from_buffer(counter, %{buffer: {queue, buffer, notifications}} = stage) do
    {queue, events, counter, buffer, notification, notifications} =
      take_from_buffer(queue, [], counter, buffer, notifications)
    # Update the buffer because dispatch events may
    # trigger more events to be buffered.
    stage = %{stage | buffer: {queue, buffer, notifications}}
    stage = dispatch_events(events, stage)
    case notification do
      {:ok, msg} ->
        take_from_buffer(counter, dispatch_notification(msg, stage))
      :error ->
        take_from_buffer(counter, stage)
    end
  end

  defp take_from_buffer(queue, events, 0, buffer, notifications) do
    {queue, Enum.reverse(events), 0, buffer, :error, notifications}
  end

  defp take_from_buffer(queue, events, counter, 0, notifications) do
    {queue, Enum.reverse(events), counter, 0, :error, notifications}
  end

  defp take_from_buffer(queue, events, counter, buffer, notifications) when is_reference(notifications) do
    {{:value, value}, queue} = :queue.out(queue)
    case value do
      {^notifications, msg} ->
        {queue, Enum.reverse(events), counter, buffer - 1, {:ok, msg}, notifications}
      val ->
        take_from_buffer(queue, [val | events], counter - 1, buffer - 1, notifications)
    end
  end

  defp take_from_buffer(queue, events, counter, buffer, wheel) do
    {{:value, value}, queue} = :queue.out(queue)

    case pop_and_increment_wheel(wheel) do
      {:ok, msg, wheel} ->
        {queue, Enum.reverse([value | events]), counter - 1, buffer - 1, {:ok, msg}, wheel}
      {:error, wheel} ->
        take_from_buffer(queue, [value | events], counter - 1, buffer - 1, wheel)
    end
  end

  defp buffer_events([], stage) do
    stage
  end
  defp buffer_events(events, %{buffer: {queue, counter, notifications},
                               buffer_config: {max, keep}} = stage) do
    {{excess, queue, counter}, pending, notifications} =
      queue_events(keep, events, queue, counter, max, notifications)

    case excess do
      0 ->
        :ok
      excess ->
        :error_logger.warning_msg('GenStage producer ~p has discarded ~p events from buffer', [name(), excess])
    end

    stage = %{stage | buffer: {queue, counter, notifications}}
    Enum.reduce(pending, stage, &dispatch_notification/2)
  end

  defp queue_events(events, queue, counter, counter, :infinity, notifications),
    do: {queue_infinity(events, queue, counter), [], notifications}
  defp queue_events(:first, events, queue, counter, max, notifications),
    do: {queue_first(events, queue, counter, max), [], notifications}
  defp queue_events(:last, events, queue, counter, max, notifications),
    do: queue_last(events, queue, 0, counter, max, [], notifications)

  defp queue_infinity([], queue, counter),
    do: {0, queue, counter}
  defp queue_infinity([event | events], queue, counter),
    do: queue_infinity(events, :queue.in(event, queue), counter + 1)

  defp queue_first([], queue, counter, _max),
    do: {0, queue, counter}
  defp queue_first(events, queue, max, max),
    do: {length(events), queue, max}
  defp queue_first([event | events], queue, counter, max),
    do: queue_first(events, :queue.in(event, queue), counter + 1, max)

  defp queue_last([], queue, excess, counter, _max, pending, wheel),
    do: {{excess, queue, counter}, Enum.reverse(pending), wheel}
  defp queue_last([event | events], queue, excess, max, max, pending, wheel) do
    queue = :queue.in(event, :queue.drop(queue))
    case pop_and_increment_wheel(wheel) do
      {:ok, notification, wheel} ->
        queue_last(events, queue, excess + 1, max, max, [notification | pending], wheel)
      {:error, wheel} ->
        queue_last(events, queue, excess + 1, max, max, pending, wheel)
    end
  end
  defp queue_last([event | events], queue, excess, counter, max, pending, wheel),
    do: queue_last(events, :queue.in(event, queue), excess, counter + 1, max, pending, wheel)

  ## Notifications helpers

  # We use a wheel unless the queue is infinity.
  defp init_wheel(:infinity), do: make_ref()
  defp init_wheel(_), do: nil

  defp producer_notify(_msg, %{type: :consumer} = stage) do
    :error_logger.error_msg('GenStage consumer ~p cannot send notifications', [name()])
    {:reply, {:error, :not_a_producer}, stage}
  end

  defp producer_notify(msg, stage) do
    %{buffer: {queue, count, notifications},
      buffer_config: {max, _keep}} = stage

    case count do
      0 ->
        {:reply, :ok, dispatch_notification(msg, stage)}
      _ when is_reference(notifications) ->
        queue = :queue.in({notifications, msg}, queue)
        {:reply, :ok, %{stage | buffer: {queue, count + 1, notifications}}}
      _ ->
        wheel = put_wheel(notifications, count, max, msg)
        {:reply, :ok, %{stage | buffer: {queue, count, wheel}}}
    end
  end

  defp put_wheel(nil, count, max, contents),
    do: {0, max, %{count - 1 => contents}}
  defp put_wheel({pos, _, wheel}, count, max, contents),
    do: {pos, max, Map.put(wheel, rem(pos + count - 1, max), contents)}

  defp pop_and_increment_wheel(nil), do: {:error, nil}
  defp pop_and_increment_wheel({pos, limit, wheel}) do
    new_pos = rem(pos + 1, limit)

    # TODO: Use :maps.take/2
    case wheel do
      %{^pos => notification} when map_size(wheel) == 1 ->
        {:ok, notification, nil}
      %{^pos => notification} ->
        {:ok, notification, {new_pos, limit, Map.delete(wheel, pos)}}
      %{} ->
        {:error, {new_pos, limit, wheel}}
    end
  end

  defp dispatch_notification(msg, stage) do
    %{dispatcher_mod: dispatcher_mod, dispatcher_state: dispatcher_state} = stage
    {:ok, dispatcher_state} = dispatcher_mod.notify(msg, dispatcher_state)
    %{stage | dispatcher_state: dispatcher_state}
  end

  ## Consumer helpers

  defp consumer_init_subscribe(producers, stage) do
    Enum.reduce producers, {:ok, stage}, fn
      to, {:ok, stage} ->
        case consumer_subscribe(to, stage) do
          {:reply, _, stage}    -> {:ok, stage}
          {:stop, reason, _, _} -> {:stop, reason}
        end
      _, {:stop, reason} ->
        {:stop, reason}
    end
  end

  defp consumer_receive({_, ref} = from, {producer_id, cancel, {demand, min, max}}, events, stage) do
    {demand, batches} = split_batches(events, from, min, max, demand, demand, [])
    stage = put_in stage.producers[ref], {producer_id, cancel, {demand, min, max}}
    {batches, stage}
  end
  defp consumer_receive(_, {_, _, :producer_consumer}, events, stage) do
    {[{events, 0}], stage}
  end
  defp consumer_receive(_, {_, _, :manual}, events, stage) do
    {[{events, 0}], stage}
  end

  defp split_batches([], _from, _min, _max, _old_demand, new_demand, batches) do
    {new_demand, Enum.reverse(batches)}
  end
  defp split_batches(events, from, min, max, old_demand, new_demand, batches) do
    {events, batch, batch_size} = split_events(events, max - min, 0, [])

    # Adjust the batch size to whatever is left of the demand in case of excess.
    {old_demand, batch_size} =
      case old_demand - batch_size do
        diff when diff < 0 ->
          :error_logger.error_msg('GenStage consumer ~p has received ~p events in excess from: ~p~n',
                                  [name(), abs(diff), from])
          {0, old_demand}
        diff ->
          {diff, batch_size}
      end

    # In case we've reached min, we will ask for more events.
    {new_demand, batch_size} =
      case new_demand - batch_size do
        diff when diff <= min ->
          {max, max - diff}
        diff ->
          {diff, 0}
      end

    split_batches(events, from, min, max, old_demand, new_demand, [{batch, batch_size} | batches])
  end

  defp split_events(events, limit, limit, acc),
    do: {events, Enum.reverse(acc), limit}
  defp split_events([], _limit, counter, acc),
    do: {[], Enum.reverse(acc), counter}
  defp split_events([event | events], limit, counter, acc),
    do: split_events(events, limit, counter + 1, [event | acc])

  defp consumer_dispatch([{batch, ask} | batches], from, mod, state, stage, _hibernate?) do
    case mod.handle_events(batch, from, state) do
      {:noreply, events, state} when is_list(events) ->
        stage = dispatch_events(events, stage)
        ask > 0 and ask(from, ask, [:noconnect])
        consumer_dispatch(batches, from, mod, state, stage, false)
      {:noreply, events, state, :hibernate} when is_list(events) ->
        stage = dispatch_events(events, stage)
        ask > 0 and ask(from, ask, [:noconnect])
        consumer_dispatch(batches, from, mod, state, stage, true)
      {:stop, reason, state} ->
        {:stop, reason, %{stage | state: state}}
      other ->
        {:stop, {:bad_return_value, other}, %{stage | state: state}}
    end
  end

  defp consumer_dispatch([], _from, _mod, state, stage, false) do
    {:noreply, %{stage | state: state}}
  end
  defp consumer_dispatch([], _from, _mod, state, stage, true) do
    {:noreply, %{stage | state: state}, :hibernate}
  end

  defp consumer_subscribe({to, opts}, stage) when is_list(opts),
    do: consumer_subscribe(to, opts, stage)
  defp consumer_subscribe(to, stage),
    do: consumer_subscribe(to, [], stage)

  defp consumer_subscribe(to, _opts, %{type: :producer} = stage) do
    :error_logger.error_msg('GenStage producer ~p cannot be subscribed to another stage: ~p~n', [name(), to])
    {:reply, {:error, :not_a_consumer}, stage}
  end

  defp consumer_subscribe(to, full_opts, stage) do
    with {:ok, cancel, opts} <- validate_in(full_opts, :cancel, :permanent, [:temporary, :permanent]),
         {:ok, max, opts} <- validate_integer(opts, :max_demand, 1000, 1, :infinity, false),
         {:ok, min, opts} <- validate_integer(opts, :min_demand, div(max, 2), 0, max - 1, false) do
      producer_pid = GenServer.whereis(to)
      cond do
        producer_pid != nil ->
          ref = Process.monitor(producer_pid)
          send_noconnect(producer_pid, {:"$gen_producer", {self(), ref}, {:subscribe, opts}})
          stage = put_in stage.monitors[ref], {producer_pid, cancel, min, max, full_opts}
          {:reply, {:ok, ref}, stage}
        cancel == :temporary ->
          {:reply, {:ok, make_ref()}, stage}
        cancel == :permanent ->
          {:stop, :noproc, {:ok, make_ref()}, stage}
       end
    else
      {:error, message} ->
        :error_logger.error_msg('GenStage consumer ~p subscribe received invalid option: ~ts~n', [name(), message])
        {:reply, {:error, {:bad_opts, message}}, stage}
    end
  end

  defp consumer_no_ack(cancel, reason, stage) do
    case cancel do
      :temporary -> {:noreply, stage}
      :permanent -> {:stop, reason, stage}
    end
  end

  defp consumer_cancel(ref, kind, reason, %{producers: producers, state: state} = stage) do
    case Map.pop(producers, ref) do
      {nil, _producers} ->
        {:noreply, stage}
      {{producer_pid, mode, _}, producers} ->
        Process.demonitor(ref, [:flush])
        stage = %{stage | producers: producers}
        case noreply_callback(:handle_cancel, [{kind, reason}, {producer_pid, ref}, state], stage) do
          {:noreply, stage} when mode == :permanent ->
            {:stop, reason, stage}
          other ->
            other
        end
    end
  end

  ## Producer consumer helpers

  defp split_pc_events(events, ref, 0, acc),
    do: {Enum.reverse(acc), put_pc_events(events, ref, :queue.new)}
  defp split_pc_events([], _from, counter, acc),
    do: {Enum.reverse(acc), counter}
  defp split_pc_events([event | events], ref, counter, acc),
    do: split_pc_events(events, ref, counter - 1, [event | acc])

  defp put_pc_events(events, ref, queue) do
    :queue.in({events, length(events), ref}, queue)
  end

  defp send_pc_events(events, ref,
                      %{mod: mod, state: state, producers: producers} = stage) do
    case producers do
      %{^ref => entry} ->
        {producer_id, _, _} = entry
        from = {producer_id, ref}
        {batches, stage} = consumer_receive(from, entry, events, stage)
        consumer_dispatch(batches, from, mod, state, stage, false)
      %{} ->
        # We queued but producer was removed
        consumer_dispatch([{events, 0}], :unused, mod, state, stage, false)
    end
  end

  defp take_pc_events(queue, counter, stage) do
    case :queue.out(queue) do
      {{:value, {events, length, ref}}, queue} when length < counter ->
        case send_pc_events(events, ref, stage) do
          {:noreply, stage} ->
            take_pc_events(queue, counter - length, stage)
          {:noreply, stage, :hibernate} ->
            take_pc_events(queue, counter - length, stage)
          {:stop, _, _} = stop ->
            stop
        end
      {{:value, {events, _length, ref}}, queue} ->
        {now, later} = Enum.split(events, counter)
        events = put_pc_events(later, ref, queue)
        send_pc_events(now, ref, %{stage | events: events})
      {:empty, _queue} ->
        {:noreply, %{stage | events: 0}}
    end
  end
end
