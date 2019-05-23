-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)
local base = require("program.l2vpn.tunnels.base").tunnel
local gre = require("lib.protocol.gre")

tunnel = setmetatable({}, { __index = base })

function tunnel:new (config)
   local function create_headers (vc_id)
      local header = gre:new({ protocol = 0x6558,
                               checksum = false,
                               key = vc_id })
      return header, header
   end
   unknown_header = function(self, p, ancillary_data)
      if self.logger and self.logger:can_log() then
         local gre = assert(self.header_scratch:new_from_mem(p.data, p.length))
         local src, dst = ancillary_data.remote_addr, ancillary_data.local_addr
         local key = gre:key()
         if key >= 0x8000 then
            self.logger:log(("%s => %s : control-channel packet for unknown "
                             .."VC ID %d"):format(src, dst, key - 0x8000))
         else
            self.logger:log(("%s => %s : data packet for unknown "
                             .."VC ID %d"):format(src, dst, key))
         end
      end
   end

   -- The base GRE header does not include the key field
   local header_size = gre:new({ key = 0}):sizeof()
   return self:_new(config, "GRE", gre, header_size, {}, create_headers,
                    unknown_header)
end

function tunnel:info ()
   return {
      params = {},
      proto = 47,
      mk_vc_config_fn = function (vc_id, cc_vc_id, tunnel_config)
         return {
            [vc_id] = {},
            [cc_vc_id] = {}
         }
      end,
      vc_id_max = 0x7FFF,
      afs = {
         ipv4 = true,
         ipv6 = true
      }
   }
end

function selftest ()
   local app_graph = config.new()
   local Source = require("apps.basic.basic_apps").Source
   local Sink = require("apps.basic.basic_apps").Sink
   local Join = require("apps.basic.basic_apps").Join

   local SourceGRE = {}
   function SourceGRE:new (key)
      local dgram = require("lib.protocol.datagram"):new()
      dgram:push(gre:new({ protocol = 0x6558,
                           checksum = false,
                           key = key }))

      return setmetatable({ dgram = dgram }, { __index = SourceGRE })
   end
   function SourceGRE:pull ()
      for _ = 1, engine.pull_npackets do
         link.transmit(self.output.output, packet.clone(self.dgram:packet()))
      end
   end

   local vcs = {}
   local nvcs = 4
   for vc_id = 1, nvcs do
      vcs[tostring(vc_id)] = {}

      config.app(app_graph, vc_id.."_south", SourceGRE, vc_id)
      config.app(app_graph, vc_id.."_north", Source)
      config.app(app_graph, vc_id.."_sink", Sink)

      config.link(app_graph, vc_id.."_south.output -> join."..vc_id)
      config.link(app_graph, "gre.vc_"..vc_id.." -> "..vc_id.."_sink.input")
      config.link(app_graph, vc_id.."_north.output -> gre.vc_"..vc_id)
   end
   config.app(app_graph, "noise", SourceGRE, 0xdead)
   config.link(app_graph, "noise.output -> join.noise")

   config.app(app_graph, "join", Join)
   config.app(app_graph, "gre", tunnel,
              { vcs = vcs,
                ancillary_data = {
                   local_addr = "::",
                   remote_addr = "::"
   } })
   config.app(app_graph, "sink", Sink)

   config.link(app_graph, "join.output -> gre.south")
   config.link(app_graph, "gre.south -> sink.input")

   engine.configure(app_graph)
   engine.main({ duration = 1 })

   local counter = require("core.counter")
   local function packets (app, link, dir)
      local at = engine.app_table[app]
      return tonumber(counter.read(at[dir][link].stats.rxpackets))
   end

   for vc_id = 1, nvcs do
      assert(packets(vc_id.."_south", "output", "output") ==
                packets("gre", "vc_"..vc_id, "output"))
   end
end
