-- Montior wiki https://wiki.hypr.land/Configuring/Basics/Monitors/

-- BenQ external monitor on the left
hl.monitor({
    output    = "desc:BNQ BenQ GL2250H 8AG02365019",
    mode      = "preferred",
    position  = "0x0",
    scale     = "1",
})

-- Laptop panel to the right of the BenQ (1920px wide at scale 1)
hl.monitor({
    output    = "desc:BOE NE153QDM-NZ2",
    mode      = "preferred",
    position  = "1920x0",
    scale     = "1.6",
})

-- Fallback for any other monitor
hl.monitor({
    output    = "",
    mode      = "preferred",
    position  = "auto",
    scale     = "auto",
})
