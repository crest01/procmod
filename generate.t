local S = require("qs.lib.std")
local procmod = require("procmod")
local globals = require("globals")
local future = require("prob.future")


local function run(generations)

	local progname = globals.config.program
	assert((not string.find(progname, "_future") and (not string.find(progname, "_mh"))),
		string.format("Config file should specify the *base* name of the model program; given name was %s", progname))
	if globals.config.method == "smc" or globals.config.method == "pcascade" or globals.config.method == "pgibbs" then
		progname = progname .. "_future"
	elseif globals.config.method == "mh" then
		progname = progname .. "_mh"
	end
	local program = require(progname)

	future.setImpl(globals.config.futureImpl)

	local smcopts = {
		nParticles = globals.config.nSamples,		
		recordHistory = globals.config.smc_recordHistory,
		saveSampleValues = globals.config.saveSampleValues,
		verbose = globals.config.verbose
	}

	local pgibbsopts = {
		nParticles = globals.config.nSamples,
		nSweeps = globals.config.pgibbs_nSweeps,
		saveSampleValues = globals.config.saveSampleValues,
		verbose = globals.config.verbose
	}

	local pcascadeopts = {
		nParticles = globals.config.nSamples,
		nMax = globals.config.pcascade_nMax,
		saveSampleValues = globals.config.saveSampleValues,
		verbose = globals.config.verbose
	}

	local mhopts = {
		nSamples = globals.config.nSamples,
		timeBudget = globals.config.mh_timeBudget,
		saveSampleValues = globals.config.saveSampleValues,
		verbose = globals.config.verbose,
		temp = globals.config.mh_temp,
		parallelTempering = globals.config.parallelTempering,
		temps = globals.config.mhpt_temperatures,
		depthBiasedVarSelect = globals.config.mh_depthBiasedVarSelect
	}

	local method = globals.config.method
	if method == "smc" then
		procmod.SIR(program, generations, smcopts)
	elseif method == "pgibbs" then
		procmod.ParticleGibbs(program, generations, pgibbsopts)
	elseif method == "pcascade" then
		procmod.ParticleCascade(program, generations, pcascadeopts)
	elseif method == "mh" then
		procmod.MH(program, generations, mhopts)
	elseif method == "reject" then
		procmod.RejectionSample(program, generations, 1)
	elseif method == "forward" then
		procmod.ForwardSample(program, generations, 1)
	else
		error(string.format("Unrecognized sampling method %s", method))
	end
end
local runterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample))}->{}, run)

local function rerun(generations, index)
	procmod.HighResRerunRecordedTrace(generations, index)
end
local rerunterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample)), uint}->{}, rerun)

return
{
	generate = terra(generations: &S.Vector(S.Vector(procmod.Sample)))
		generations:clear()
		runterra(generations)
	end,
	highResRerun = terra(generations: &S.Vector(S.Vector(procmod.Sample)), index: uint)
		rerunterra(generations, index)
	end
}



