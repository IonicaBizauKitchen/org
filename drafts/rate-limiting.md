Rate limiting 

## Time Bucketed (#time-bucketed)

A very simple rate limiting implementation is to simply bucket the remaining
limit for a certain amount of time. Start a bucket when the first action comes
in, decrement its value as more actions appear, and expire the bucket after the
configured rate limiting period. The pseudo-code might look like the following:

``` ruby
# 5000 allowed actions per hour
RATE_BURST  = 5000
RATE_PERIOD = 1.hour

def rate_limit?(bucket)
  if !bucket.exists?
    bucket.set_value(RATE_BURST)
    bucket.set_ttl(RATE_PERIOD)
  end

  if bucket.value > 0
    bucket.decrement
    true
  else
    false
  end
end
```

The Redis `SETEX` command makes this trivial to implement; just set a key
containing the remaining limit with the appropriate expiry and let Redis take
care of clean-up.

### Downsides (#time-bucketed-downsides)

This method can be somewhat unforgiving for users because it allows a buggy or
rogue script to burn an account's entire rate limit immediately, and force them
to wait for the next reset event to be able to get access back.

By the same principle, the algorithm can be dangerous to the server as well.
Consider an antisocial script that can make enough concurrent requests that it
can exhaust its rate limit in short order and which is regularly overlimit.
Once an hour as the limit resets, the script bombards the server with a new
series of requests until its rate is exhausted once again. In this scenario the
server always needs enough extra capacity to handle these short intense bursts
and which will likely go to waste during the rest of the hour. This wouldn't be
the case if we could find an algorithm that would force these requests to be
more evenly spaced out.

GitHub's API is one such service that implements this naive algorithm (I will
randomly pick on them, but many others do this as well), and I can use it to
easily demonstrate this problem:

``` sh
```

I'll be locked out for the next hour:

``` sh
$ curl --silent --head -i -H "Authorization: token $GITHUB_TOKEN" \
    https://api.github.com/users/brandur | grep RateLimit-Reset
X-RateLimit-Reset: 1442423816

$ RESET=1442423816 ruby -e 'puts "%.0f minute(s) before reset" % \
    ((Time.at(ENV["RESET"].to_i) - Time.now) / 60)'
29 minute(s) before reset
```

## Leaky Bucket (#leaky-bucket)

Luckily, an algorithm exists that can take care of the problem of this sort of
jagged rate limiting called the [leaky bucket][leaky-bucket]. It's very
intuitive to understand by simply comparing it to its real-world namesake:
imagine a bucket partially filled with water and which has some fixed capacity
(τ). The bucket has a leak so that some amount of water is escaping at a
constant rate (T). Whenever an action that should be rate limited occurs, some
amount of water flows into the bucket, with the amount being proportional to
its relative costliness. If the amount of water entering the bucket is greater
than the amount leaving through the leak, the bucket starts to fill. Actions
are disallowed if the bucket is full.

``` monodraw
          ***      User                           
      │   ***    actions                          
      │            add                            
      │          "water"                          
      │                                           
      │                                           
═╗    ▼   ***        ╔═       ▲                   
 ║        ***        ║        │                   
 ║                   ║        │                   
 ║                   ║   τ = Bucket               
 ║                   ║    capacity                
 ║*******************║        │                   
 ║*******************║        │                   
 ║*******************║        │                   
 ╚════════╗*╔════════╝        ▼                   
          ║*║                                     
         ═╝*╚═                                    
           *                 ┌──────────────────┐ 
      │    *                 │                  │░
      │    *    Constant     │   LEAKY BUCKET   │░
      │    *    drip out     │                  │░
      ▼    *                 └──────────────────┘░
           *                  ░░░░░░░░░░░░░░░░░░░░
```

The leaky bucket produces a very smooth rate limiting effect. A user can still
exhaust their entire quota by filling their entire bucket nearly
instantaneously, but after realizing the error, they should still have access
to more quota fairly quickly as the leak starts to drain the bucket
immediately.

The leaky bucket is normally implemented using a background process that
simulates a leak. It looks for any active buckets that need to be drained, and
drains each one in turn. In Redis, this might look like a hash that groups all
buckets under a type of rate limit and which is dripped by iterating each key
and decrementing it.

### Downsides (#leaky-bucket-downsides)

The naive leaky bucket's greatness weakness is its "drip" process. If it goes
offline or gets to a capacity limit where it can't drip all the buckets that
need to be dripped, then new incoming requests might be limited incorrectly.
There are a number of strategies to help avoid this danger, but if we could
build an algorithm without a drip, it would be fundamentally more stable.

## GCRA (#gcra)

This leads us to the leaky bucket variant called ["Generic Cell Rate
Algorithm"][gcra] (GCRA). The name "cell" comes from a communications
technology called [Asynchronous Transfer Mode][atm] (ATM) which encoded data
into small packets of fixed size called "cells" (as opposed to the variable
size frames of IP). GCRA was the algorithm recommended by the [ATM
Forum][atm-forum] for use in an ATM network's scheduler so that it could either
delay or drop cells that came in over their rate limit. Although today [ATM is
dead][atm-dead], we still catch occasional glimpses of its past innovation with
examples like GCRA.

GCRA works by tracking remaining limit through a time called the "theoretical
arrival time" (TAT), which is seeded on the first request by adding a duration
representing its cost to the current time. The cost is calculated as a
multiplier of our "emission interval" (T), which is dervied from the rate at
which we want the bucket to refill. When any subsequent request comes in, we
take the existing TAT, subtract a fixed buffer representing the limit's total
burst capacity from it (τ + T), and compare the result to the current time.
This result represents the next time to allow a request and if it's in the past
we allow the incoming request; if it's in the future, we don't. After a
successful request, a new TAT is calculated by adding T.

The pseudo-code for the algorithm can look a little daunting, so instead of
providing it, I'll recommend taking a look at our reference implementation
[Throttled](#throttled) (more on this below). Instead, let's take a look at
visual representation of the timeline and various variables for successful
request. Here we see an allowed request where t<sub>0</sub> is within the
bounds of TAT - (τ + T) (i.e. the time of the next allowed request):

``` monodraw
┌──────────────────┐                                                     
│ ALLOWED REQUEST  │░                                                    
└──────────────────┘░                                                    
 ░░░░░░░░░░░░░░░░░░░░                                                    
                                                                         
                ┌────────┐                                               
                │allow at│               ┌───────┐     ┌───────┐         
                │ (past) │               │  t0   │     │  tat  │         
                └───┬────┘               └───┬───┘     └───┬───┘         
                    │                        │             │             
                    ▼                        ▼             ▼             
────────────────────+──────────────────────────────────────+───────▶     
                    │//////////////////////////////////////│        time 
                    │//////////////////////////////////////│             
                    └──────────────────────────────────────┘             
                     ◀────────────────τ + T───────────────▶              
                                                                         
                                                                         
┌─────────────────────────────────────┐                                  
│T     = Emission interval            │░                                 
│τ     = Capacity of bucket           │░                                 
│T + τ = Delay variation tolerance    │░                                 
│tat   = Theoretical arrival time     │░                                 
│t0    = Actual time of request       │░                                 
└─────────────────────────────────────┘░                                 
 ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░                                 
```

For a failed request, the time of the next allowed request is in the future,
prompting us to deny the request:

``` monodraw
┌──────────────────┐                                                     
│  DENIED REQUEST  │░                                                    
└──────────────────┘░                                                    
 ░░░░░░░░░░░░░░░░░░░░                                                    
                                                                         
                ┌────────┐                                               
  ┌───────┐     │allow at│                             ┌───────┐         
  │  t0   │     │(future)│                             │  tat  │         
  └───┬───┘     └───┬────┘                             └───┬───┘         
      │             │                                      │             
      ▼             ▼                                      ▼             
────────────────────+──────────────────────────────────────+───────▶     
                    │//////////////////////////////////////│        time 
                    │//////////////////////////////////////│             
                    └──────────────────────────────────────┘             
                     ◀────────────────τ + T───────────────▶              
                                                                         
```

Because GCRA is so dependent on time, it's critical to have a strategy for
making sure that the current time is consistent if rate limits are being
tracked from multiple deployments. Clock drift between machines could throw off
the algorithm and lead to false positives (i.e. locked out users). One easy
strategy here is to use the store's time for synchronization (for example, by
accessing the `TIME` command in Redis).

### Throttled (#throttled)

My soon-to-be-colleague [Andrew Metcalf][andrew-metcalf] recently upgraded the
open-source Golang library [Throttled][throttled] from the naive rate limiting
implementation that it had been using to the one using GCRA. The package is
well-documented and well-tested, and should serve as a pretty intuitive
reference implementation for the curious. It's already taking production
traffic at Stripe and should be soon at Heroku as well. If any of this was of
interest to you, we'd love for you to give it a whirl.

[andrew-metcalf]: https://github.com/metcalf
[atm]: https://en.wikipedia.org/wiki/Asynchronous_Transfer_Mode
[atm-dead]: http://technologyinside.com/2007/01/31/part-1-the-demise-of-atm…/
[atm-forum]: https://en.wikipedia.org/wiki/ATM_Forum
[gcra]: https://en.wikipedia.org/wiki/Generic_cell_rate_algorithm
[leaky-bucket]: https://en.wikipedia.org/wiki/Leaky_bucket
[throttled]: https://github.com/throttled/throttled
