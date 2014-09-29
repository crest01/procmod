local S = terralib.require("qs.lib.std")
local Vec = terralib.require("linalg.vec")
local gl = terralib.require("gl.gl")



local elems = macro(function(vec)
	local T = vec:gettype()
	local N = T.Dimension
	local exps = terralib.newlist()
	for i=1,N do
		exps:insert(`vec([i-1]))
	end
	return exps
end)



-- Simple camera class that packages up data needed to establish 3D
--    viewing / projection transforms
local Camera = S.memoize(function(real)

	local Vec3 = Vec(real, 3)

	local struct Camera(S.Object)
	{
		eye: Vec3,
		target: Vec3,
		up: Vec3,
		fovy: real,	-- in degrees
		aspect: real,
		znear: real,
		zfar: real
	}

	-- Default camera is looking down -z
	terra Camera:__init()
		self.eye:init(0.0, 0.0, 0.0)
		self.target:init(0.0, 0.0, -1.0)
		self.up:init(0.0, 1.0, 0.0)
		self.fovy = 45.0
		self.aspect = 1.0
		self.znear = 1.0
		self.zfar = 100.0
	end

	terra Camera:__init(eye: Vec3, target: Vec3, up: Vec3, fovy: real, aspect: real, znear: real, zfar: real)
		self.eye = eye
		self.target = target
		self.up = up
		self.fovy = fovy
		self.aspect = aspect
		self.znear = znear
		self.zfar = zfar
	end

	-- OpenGL 1.1 style
	terra Camera:setupGLPerspectiveView()
		gl.glMatrixMode(gl.mGL_MODELVIEW())
		gl.glLoadIdentity()
		gl.gluLookAt(self.eye(0), self.eye(1), self.eye(2),
					 self.target(0), self.target(1), self.target(2),
					 self.up(0), self.up(1), self.up(2))
		gl.glMatrixMode(gl.mGL_PROJECTION())
		gl.glLoadIdentity()
		gl.gluPerspective(self.fovy, self.aspect, self.znear, self.zfar)
	end

	return Camera

end)



-- Simple light class that packages up parameters about lights
local Light = S.memoize(function(real)

	local Vec3 = Vec(real, 3)
	local Color4 = Vec(real, 4)

	local LightType = uint
	local Directional = 0
	local Point = 1

	local struct Light(S.Object)
	{
		type: LightType,
		union
		{
			pos: Vec3,
			dir: Vec3
		},
		ambient: Color4,
		diffuse: Color4,
		specular: Color4
	}
	Light.LightType = LightType
	Light.Point = Point
	Light.Directional = Directional

	terra Light:__init()
		self.type = Directional
		self.dir:init(1.0, 1.0, 1.0)
		self.ambient:init(0.3, 0.3, 0.3, 1.0)
		self.diffuse:init(1.0, 1.0, 1.0, 1.0)
		self.specular:init(1.0, 1.0, 1.0, 1.0)
	end

	terra Light:__init(type: LightType, posOrDir: Vec3, ambient: Color4, diffuse: Color4, specular: Color4) : {}
		self.type = type
		self.pos = posOrDir
		self.ambient = ambient
		self.diffuse = diffuse
		self.specular = specular
	end

	terra Light:__init(type: LightType, posOrDir: Vec3, diffuse: Color4, ambAmount: real, specular: Color4) : {}
		self.type = type
		self.pos = posOrDir
		self.ambient = ambAmount * diffuse; self.ambient(3) = self.diffuse(3)
		self.diffuse = diffuse
		self.specular = specular
	end

	-- OpenGL 1.1 style
	terra Light:setupGLLight(lightID: int)
		if lightID < 0 or lightID >= gl.mGL_MAX_LIGHTS() then
			S.printf("lightID must be in the range [0,%d); got %d instead\n", 0, gl.mGL_MAX_LIGHTS(), lightID)
			S.assert(false)
		end
		var lightNumFlag = gl.mGL_LIGHT0() + lightID
		gl.glEnable(lightNumFlag)
		var floatArr = arrayof(float, elems(self.ambient))
		gl.glLightfv(lightNumFlag, gl.mGL_AMBIENT(), floatArr)
		floatArr = arrayof(float, elems(self.diffuse))
		gl.glLightfv(lightNumFlag, gl.mGL_DIFFUSE(), floatArr)
		floatArr = arrayof(float, elems(self.specular))
		gl.glLightfv(lightNumFlag, gl.mGL_SPECULAR(), floatArr)
		-- Leverage the fact that the light type flags correspond to the value of the w coordinate
		floatArr = arrayof(float, elems(self.pos), self.type)
		gl.glLightfv(lightNumFlag, gl.mGL_POSITION(), floatArr)
	end

	return Light

end)




-- Simple material class to package up material params
local Material = S.memoize(function(real)

	local Color4 = Vec(real, 4)

	struct Material
	{
		ambient: Color4,
		diffuse: Color4,
		specular: Color4,
		shininess: real
	}

	terra Material:__init()
		self.ambient:init(0.8, 0.8, 0.8, 1.0)
		self.diffuse:init(0.8, 0.8, 0.8, 1.0)
		self.specular:init(0.0, 0.0, 0.0, 1.0)
		self.shininess = 0.0
	end

	terra Material:__init(ambient: Color4, diffuse: Color4, specular: Color4, shininess: real)
		self.ambient = ambient
		self.diffuse = diffuse
		self.specular = specular
		self.shininess = shininess
	end

	terra Material:__init(diffuse: Color4, specular: Color4, shininess: real)
		self.ambient = diffuse
		self.diffuse = diffuse
		self.specular = specular
		self.shininess = shininess
	end

	-- OpenGL 1.1 style
	terra Material:setupGLMaterial()
		-- Just default everything to only affecting the front faces
		var flag = gl.mGL_FRONT()
		var floatArr = arrayof(float, elems(self.ambient))
		gl.glMaterialfv(flag, gl.mGL_AMBIENT(), floatArr)
		floatArr = arrayof(float, elems(self.diffuse))
		gl.glMaterialfv(flag, gl.mGL_DIFFUSE(), floatArr)
		floatArr = arrayof(float, elems(self.specular))
		gl.glMaterialfv(flag, gl.mGL_SPECULAR(), floatArr)
		gl.glMaterialf(flag, gl.mGL_SHININESS(), self.shininess)
	end

	return Material

end)



return
{
	Camera = Camera,
	Light = Light,
	Material = Material
}





