# io_uring zero-copy research profile - modern kernel + 25G NICs
import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()

pc.defineParameter("nodeCount", "Number of nodes",
                   portal.ParameterType.INTEGER, 2)
pc.defineParameter("nodeType", "Hardware type",
                   portal.ParameterType.STRING, "c6525-25g",
                   [("c6525-25g", "25G Mellanox"),
                    ("d6515",     "25G Mellanox")])
# Use STRING for broad compatibility (IMAGE can be flaky on some portals)
pc.defineParameter("osImage", "OS Image",
                   portal.ParameterType.STRING,
                   "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD")

params = pc.bindParameters()
req = pc.makeRequestRSpec()

lan = pg.LAN("lan")
lan.vlan_tagging = False
lan.link_multiplexing = False
lan.bandwidth = 25 * 1000 * 1000  # ~25 Gbps in Kbps units

for i in range(params.nodeCount):
    n = pg.RawPC("node%d" % i)
    n.hardware_type = params.nodeType
    n.disk_image = params.osImage

    # Pass a role to startup.sh (node0=server, others=client)
    role = "server" if i == 0 else "client"
    n.addService(pg.Execute(shell="bash",
                            command="/local/repository/startup.sh %s" % role))

    iface = n.addInterface("if-lan%d" % i)
    iface.addAddress(pg.IPv4Address("10.10.1.%d" % (i + 1), "255.255.255.0"))
    lan.addInterface(iface)

    req.addResource(n)

req.addResource(lan)
pc.printRequestRSpec(req)
